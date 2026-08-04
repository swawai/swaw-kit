mod model;

use std::error::Error;
use std::fmt;
use std::fs;
use std::os::windows::fs::MetadataExt;
use std::path::{Path, PathBuf};

pub use model::{
    ChannelTool, DevelopmentProfile, EntryProfileRecord, GitProfile, ModeTool, Preferences,
    RepositoryProfile, RustTool, VersionedTool,
};
use windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT;

use crate::atomic_file;
use crate::binding::ProjectBinding;

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

impl EntryProfileStore {
    pub fn new(swawkit_home: impl Into<PathBuf>, data_root: impl Into<PathBuf>) -> Self {
        Self {
            swawkit_home: swawkit_home.into(),
            data_root: data_root.into(),
        }
    }

    pub fn read(&self) -> EntryProfileState {
        let path = self.path();
        match fs::symlink_metadata(&path) {
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return EntryProfileState::Missing { path };
            }
            Err(error) => {
                return EntryProfileState::Invalid {
                    path,
                    record: None,
                    error: format!("cannot inspect entry profile: {error}"),
                };
            }
        }

        let record = match read_record(&path) {
            Ok(record) => record,
            Err(error) => {
                return EntryProfileState::Invalid {
                    path,
                    record: None,
                    error: error.to_string(),
                };
            }
        };
        match self.resolve(record.clone()) {
            Ok(profile) => EntryProfileState::Ready(profile),
            Err(error) => EntryProfileState::Invalid {
                path,
                record: Some(record),
                error: error.to_string(),
            },
        }
    }

    pub fn save(&self, record: EntryProfileRecord) -> Result<EntryProfile, ProfileError> {
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
        Ok(profile)
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
}

fn read_record(path: &Path) -> Result<EntryProfileRecord, ProfileError> {
    validate_publication_target(path)?;
    let content = fs::read_to_string(path).map_err(|error| {
        ProfileError::new(format!(
            "cannot read entry profile '{}': {error}",
            path.display()
        ))
    })?;
    serde_json::from_str(&content)
        .map_err(|error| ProfileError::new(format!("invalid entry profile JSON: {error}")))
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProfileError {
    message: String,
}

impl ProfileError {
    pub(crate) fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl fmt::Display for ProfileError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl Error for ProfileError {}

#[cfg(test)]
mod tests;
