mod document;
mod error;
mod language;
mod model;
mod storage;

use std::fs;
use std::path::PathBuf;

pub use document::{ENTRY_CONFIG_DOCUMENT_PROTOCOL, EntryConfigDocument};
pub use error::{EntryConfigError, EntryConfigUpdateError};
pub use language::{DEFAULT_LANGUAGE, EntryLanguage};
pub use model::{EntryConfigRecord, LANGUAGE_ADDRESS, PROJECT_ROOT_ADDRESS};

use crate::atomic_file;
use crate::binding::ProjectBinding;
use crate::data_root::DataRootLock;
use storage::{
    read_input_record, read_record, revision, validate_data_root, validate_publication_target,
};

pub const ENTRY_CONFIG_SCHEMA: &str = "swawkit.entry-config/v1";
pub const ENTRY_CONFIG_FILE: &str = "_entry-config.json";
pub const ENTRY_CONFIG_MAX_BYTES: u64 = 64 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EntryConfig {
    record: EntryConfigRecord,
    binding: Option<ProjectBinding>,
    binding_error: Option<String>,
    revision: String,
}

impl EntryConfig {
    pub fn record(&self) -> &EntryConfigRecord {
        &self.record
    }

    pub fn binding(&self) -> Option<&ProjectBinding> {
        self.binding.as_ref()
    }

    pub fn binding_error(&self) -> Option<&str> {
        self.binding_error.as_deref()
    }

    pub fn language(&self) -> EntryLanguage {
        EntryLanguage::parse(&self.record.language)
            .expect("a resolved Entry Config must have a supported language")
    }

    pub fn revision(&self) -> &str {
        &self.revision
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EntryConfigState {
    Default { path: PathBuf },
    Invalid { path: PathBuf, error: String },
    Ready(EntryConfig),
}

impl EntryConfigState {
    pub fn ready(&self) -> Option<&EntryConfig> {
        match self {
            Self::Ready(config) => Some(config),
            Self::Default { .. } | Self::Invalid { .. } => None,
        }
    }

    pub fn language(&self) -> EntryLanguage {
        self.ready().map(EntryConfig::language).unwrap_or_default()
    }

    pub fn binding(&self) -> Option<&ProjectBinding> {
        self.ready().and_then(EntryConfig::binding)
    }
}

#[derive(Debug, Clone)]
pub struct EntryConfigStore {
    swawkit_home: PathBuf,
    data_root: PathBuf,
}

struct ConfigSnapshot {
    state: EntryConfigState,
    revision: String,
}

impl EntryConfigStore {
    pub fn new(swawkit_home: impl Into<PathBuf>, data_root: impl Into<PathBuf>) -> Self {
        Self {
            swawkit_home: swawkit_home.into(),
            data_root: data_root.into(),
        }
    }

    pub fn read(&self) -> EntryConfigState {
        self.snapshot().state
    }

    pub fn document(&self) -> EntryConfigDocument {
        let snapshot = self.snapshot();
        EntryConfigDocument::from_state(
            snapshot.state,
            self.path().display().to_string(),
            snapshot.revision,
        )
    }

    pub fn save(&self, record: EntryConfigRecord) -> Result<EntryConfig, EntryConfigError> {
        let lock = self.acquire_lock()?;
        self.commit_locked(&lock, record)
    }

    pub fn replace(
        &self,
        record: EntryConfigRecord,
    ) -> Result<EntryConfigDocument, EntryConfigError> {
        let lock = self.acquire_lock()?;
        let config = self.commit_locked(&lock, record)?;
        Ok(self.ready_document(config))
    }

    pub fn replace_from_file(
        &self,
        path: &std::path::Path,
    ) -> Result<EntryConfigDocument, EntryConfigError> {
        self.replace(read_input_record(path)?)
    }

    pub fn update_setting(
        &self,
        address: &str,
        value: Option<String>,
    ) -> Result<EntryConfigDocument, EntryConfigError> {
        let lock = self.acquire_lock()?;
        let current = self.snapshot();
        let mut record = record_for_update(current.state)?;
        record.set_setting(address, value)?;
        let config = self.commit_locked(&lock, record)?;
        Ok(self.ready_document(config))
    }

    pub fn update_setting_if_revision(
        &self,
        expected_revision: &str,
        address: &str,
        value: Option<String>,
    ) -> Result<EntryConfigDocument, EntryConfigUpdateError> {
        let lock = self
            .acquire_lock()
            .map_err(EntryConfigUpdateError::Config)?;
        let current = self.snapshot();
        if current.revision != expected_revision {
            return Err(EntryConfigUpdateError::Conflict {
                current_revision: current.revision,
            });
        }
        let mut record =
            record_for_update(current.state).map_err(EntryConfigUpdateError::Config)?;
        record
            .set_setting(address, value)
            .map_err(EntryConfigUpdateError::Config)?;
        let config = self
            .commit_locked(&lock, record)
            .map_err(EntryConfigUpdateError::Config)?;
        Ok(self.ready_document(config))
    }

    pub fn path(&self) -> PathBuf {
        self.data_root.join(ENTRY_CONFIG_FILE)
    }

    fn snapshot(&self) -> ConfigSnapshot {
        let path = self.path();
        match fs::symlink_metadata(&path) {
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return ConfigSnapshot {
                    state: EntryConfigState::Default { path },
                    revision: "missing".to_owned(),
                };
            }
            Err(error) => {
                return ConfigSnapshot {
                    state: EntryConfigState::Invalid {
                        path,
                        error: format!("cannot inspect entry config: {error}"),
                    },
                    revision: "unavailable".to_owned(),
                };
            }
        }

        let (record, revision) = match read_record(&path) {
            Ok(result) => result,
            Err(error) => {
                return ConfigSnapshot {
                    state: EntryConfigState::Invalid {
                        path,
                        error: error.to_string(),
                    },
                    revision: error.revision.unwrap_or_else(|| "unavailable".to_owned()),
                };
            }
        };
        let state = match self.resolve(record.clone(), revision.clone()) {
            Ok(config) => EntryConfigState::Ready(config),
            Err(error) => EntryConfigState::Invalid {
                path,
                error: error.to_string(),
            },
        };
        ConfigSnapshot { state, revision }
    }

    fn resolve(
        &self,
        record: EntryConfigRecord,
        revision: String,
    ) -> Result<EntryConfig, EntryConfigError> {
        record.validate()?;
        let (binding, binding_error) = match record
            .project_root
            .as_deref()
            .map(|root| ProjectBinding::resolve(&self.swawkit_home, root))
            .transpose()
        {
            Ok(binding) => (binding, None),
            Err(error) => (None, Some(error.to_string())),
        };
        Ok(EntryConfig {
            record,
            binding,
            binding_error,
            revision,
        })
    }

    fn commit_locked(
        &self,
        _lock: &DataRootLock,
        record: EntryConfigRecord,
    ) -> Result<EntryConfig, EntryConfigError> {
        validate_data_root(&self.data_root)?;
        let mut content = serde_json::to_vec_pretty(&record).map_err(|error| {
            EntryConfigError::new(format!("cannot serialize entry config: {error}"))
        })?;
        content.push(b'\n');
        if content.len() as u64 > ENTRY_CONFIG_MAX_BYTES {
            return Err(EntryConfigError::new(format!(
                "serialized Entry Config exceeds the {ENTRY_CONFIG_MAX_BYTES}-byte protocol limit"
            )));
        }
        let revision = revision(&content);
        let config = self.resolve(record, revision)?;
        let path = self.path();
        validate_publication_target(&path)?;
        atomic_file::publish(&path, &content).map_err(|error| {
            EntryConfigError::new(format!(
                "cannot publish entry config '{}': {error}",
                path.display()
            ))
        })?;
        Ok(config)
    }

    fn ready_document(&self, config: EntryConfig) -> EntryConfigDocument {
        let revision = config.revision().to_owned();
        EntryConfigDocument::from_state(
            EntryConfigState::Ready(config),
            self.path().display().to_string(),
            revision,
        )
    }

    fn acquire_lock(&self) -> Result<DataRootLock, EntryConfigError> {
        let data_directory = self.data_root.parent().ok_or_else(|| {
            EntryConfigError::new(format!(
                "Entry Config DataRoot has no data directory: {}",
                self.data_root.display()
            ))
        })?;
        DataRootLock::acquire(data_directory)
            .map_err(|error| EntryConfigError::new(error.to_string()))
    }
}

fn record_for_update(state: EntryConfigState) -> Result<EntryConfigRecord, EntryConfigError> {
    match state {
        EntryConfigState::Default { .. } => Ok(EntryConfigRecord::default()),
        EntryConfigState::Ready(config) => Ok(config.record().clone()),
        EntryConfigState::Invalid { error, .. } => Err(EntryConfigError::new(format!(
            "cannot update one setting because the current Entry Config is invalid: {error}. Replace it with '.entry/apply --file <path>'"
        ))),
    }
}

#[cfg(test)]
mod tests;
