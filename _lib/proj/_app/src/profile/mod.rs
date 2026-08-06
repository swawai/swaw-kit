mod document;
mod error;
mod model;
mod variables;

use std::fs;
use std::os::windows::fs::MetadataExt;
use std::path::{Path, PathBuf};

pub use document::EntryProfileDocument;
use error::ProfileReadError;
pub use error::{ProfileError, ProfileUpdateError};
pub use model::{
    ChannelTool, DevelopmentProfile, EntryProfileRecord, GitProfile, ModeTool, Preferences,
    RepositoryProfile, RustTool, VersionedTool,
};
use sha2::{Digest, Sha256};
use windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT;

use crate::atomic_file;
use crate::binding::ProjectBinding;
use crate::data_root::DataRootLock;

pub const PROFILE_SCHEMA: &str = "swawkit.entry-profile/v1";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EntryProfile {
    record: EntryProfileRecord,
    binding: ProjectBinding,
}

impl EntryProfile {
    pub fn record(&self) -> &EntryProfileRecord {
        &self.record
    }

    pub fn binding(&self) -> &ProjectBinding {
        &self.binding
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EntryProfileState {
    Missing {
        path: PathBuf,
    },
    Invalid {
        path: PathBuf,
        record: Option<EntryProfileRecord>,
        error: String,
    },
    Ready(EntryProfile),
}

impl EntryProfileState {
    pub fn ready(&self) -> Option<&EntryProfile> {
        match self {
            Self::Ready(profile) => Some(profile),
            Self::Missing { .. } | Self::Invalid { .. } => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct EntryProfileStore {
    swawkit_home: PathBuf,
    data_root: PathBuf,
}

struct ProfileSnapshot {
    state: EntryProfileState,
    revision: String,
}

impl EntryProfileStore {
    pub fn new(swawkit_home: impl Into<PathBuf>, data_root: impl Into<PathBuf>) -> Self {
        Self {
            swawkit_home: swawkit_home.into(),
            data_root: data_root.into(),
        }
    }

    pub fn read(&self) -> EntryProfileState {
        self.snapshot().state
    }

    fn snapshot(&self) -> ProfileSnapshot {
        let path = self.path();
        match fs::symlink_metadata(&path) {
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return ProfileSnapshot {
                    state: EntryProfileState::Missing { path },
                    revision: "missing".to_owned(),
                };
            }
            Err(error) => {
                return ProfileSnapshot {
                    state: EntryProfileState::Invalid {
                        path,
                        record: None,
                        error: format!("cannot inspect entry profile: {error}"),
                    },
                    revision: "unavailable".to_owned(),
                };
            }
        }

        let (record, revision) = match read_record(&path) {
            Ok(result) => result,
            Err(error) => {
                return ProfileSnapshot {
                    state: EntryProfileState::Invalid {
                        path,
                        record: None,
                        error: error.to_string(),
                    },
                    revision: error.revision.unwrap_or_else(|| "unavailable".to_owned()),
                };
            }
        };
        let state = match self.resolve(record.clone()) {
            Ok(profile) => EntryProfileState::Ready(profile),
            Err(error) => EntryProfileState::Invalid {
                path,
                record: Some(record),
                error: error.to_string(),
            },
        };
        ProfileSnapshot { state, revision }
    }

    pub fn save(&self, record: EntryProfileRecord) -> Result<EntryProfile, ProfileError> {
        let _lock = self.acquire_lock()?;
        self.save_locked(record).map(|(profile, _)| profile)
    }

    fn save_locked(
        &self,
        record: EntryProfileRecord,
    ) -> Result<(EntryProfile, String), ProfileError> {
        validate_data_root(&self.data_root)?;
        let profile = self.resolve(record)?;
        let mut content = serde_json::to_string_pretty(profile.record()).map_err(|error| {
            ProfileError::new(format!("cannot serialize entry profile: {error}"))
        })?;
        content.push('\n');
        let path = self.path();
        validate_publication_target(&path)?;
        atomic_file::publish(&path, content.as_bytes()).map_err(|error| {
            ProfileError::new(format!(
                "cannot publish entry profile '{}': {error}",
                path.display()
            ))
        })?;
        let revision = revision(content.as_bytes());
        Ok((profile, revision))
    }

    pub fn document(&self) -> EntryProfileDocument {
        let snapshot = self.snapshot();
        EntryProfileDocument::from_state(
            snapshot.state,
            self.path().display().to_string(),
            snapshot.revision,
        )
    }

    pub fn update_environment_variable(
        &self,
        name: &str,
        value: String,
    ) -> Result<EntryProfileDocument, ProfileError> {
        let _lock = self.acquire_lock()?;
        let mut record = record_for_variable_update(self.snapshot().state)?;
        record.set_environment_variable(name, value)?;
        let (profile, revision) = self.save_locked(record)?;
        Ok(EntryProfileDocument::from_state(
            EntryProfileState::Ready(profile),
            self.path().display().to_string(),
            revision,
        ))
    }

    pub fn replace(
        &self,
        record: EntryProfileRecord,
    ) -> Result<EntryProfileDocument, ProfileError> {
        let _lock = self.acquire_lock()?;
        let (profile, revision) = self.save_locked(record)?;
        Ok(EntryProfileDocument::from_state(
            EntryProfileState::Ready(profile),
            self.path().display().to_string(),
            revision,
        ))
    }

    pub fn update_environment_variable_if_revision(
        &self,
        expected_revision: &str,
        name: &str,
        value: String,
    ) -> Result<EntryProfileDocument, ProfileUpdateError> {
        let _lock = self.acquire_lock().map_err(ProfileUpdateError::Profile)?;
        let current = self.snapshot();
        if current.revision != expected_revision {
            return Err(ProfileUpdateError::Conflict {
                current_revision: current.revision,
            });
        }
        let mut record = record_for_variable_update(current.state)
            .map_err(ProfileUpdateError::Profile)?;
        record
            .set_environment_variable(name, value)
            .map_err(ProfileUpdateError::Profile)?;
        let (profile, revision) = self
            .save_locked(record)
            .map_err(ProfileUpdateError::Profile)?;
        Ok(EntryProfileDocument::from_state(
            EntryProfileState::Ready(profile),
            self.path().display().to_string(),
            revision,
        ))
    }

    pub fn path(&self) -> PathBuf {
        self.data_root.join("_profile.json")
    }

    fn resolve(&self, record: EntryProfileRecord) -> Result<EntryProfile, ProfileError> {
        record.validate()?;
        let binding = ProjectBinding::resolve(&self.swawkit_home, &record.target_project_root)
            .map_err(|error| ProfileError::new(error.to_string()))?;
        Ok(EntryProfile { record, binding })
    }

    fn acquire_lock(&self) -> Result<DataRootLock, ProfileError> {
        let data_directory = self.data_root.parent().ok_or_else(|| {
            ProfileError::new(format!(
                "entry profile DataRoot has no data directory: {}",
                self.data_root.display()
            ))
        })?;
        DataRootLock::acquire(data_directory).map_err(|error| ProfileError::new(error.to_string()))
    }
}

fn record_for_variable_update(
    state: EntryProfileState,
) -> Result<EntryProfileRecord, ProfileError> {
    match state {
        EntryProfileState::Missing { .. } => Ok(EntryProfileRecord::default()),
        EntryProfileState::Invalid {
            record: Some(record),
            ..
        } => Ok(record),
        EntryProfileState::Invalid {
            record: None,
            error,
            ..
        } => Err(ProfileError::new(format!(
            "cannot update one variable because the current profile is unreadable: {error}. Replace it with '..entry.apply --file <path>'"
        ))),
        EntryProfileState::Ready(profile) => Ok(profile.record().clone()),
    }
}

fn read_record(path: &Path) -> Result<(EntryProfileRecord, String), ProfileReadError> {
    validate_publication_target(path)?;
    let content = fs::read(path).map_err(|error| {
        ProfileReadError::new(format!(
            "cannot read entry profile '{}': {error}",
            path.display()
        ))
    })?;
    let revision = revision(&content);
    serde_json::from_slice(&content)
        .map(|record| (record, revision.clone()))
        .map_err(|error| {
            ProfileReadError::with_revision(
                format!("invalid entry profile JSON: {error}"),
                revision,
            )
        })
}

fn revision(content: &[u8]) -> String {
    format!("sha256-{:x}", Sha256::digest(content))
}

fn validate_data_root(data_root: &Path) -> Result<(), ProfileError> {
    let metadata = fs::symlink_metadata(data_root).map_err(|error| {
        ProfileError::new(format!(
            "cannot inspect entry profile DataRoot '{}': {error}",
            data_root.display()
        ))
    })?;
    if !metadata.is_dir() || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(ProfileError::new(format!(
            "entry profile DataRoot must be a regular directory: {}",
            data_root.display()
        )));
    }
    Ok(())
}

fn validate_publication_target(path: &Path) -> Result<(), ProfileError> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(ProfileError::new(format!(
                "cannot inspect entry profile '{}': {error}",
                path.display()
            )));
        }
    };
    if !metadata.is_file() || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(ProfileError::new(format!(
            "entry profile must be a regular file: {}",
            path.display()
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests;
