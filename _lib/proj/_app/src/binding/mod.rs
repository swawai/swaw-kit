use std::error::Error;
use std::fmt;
use std::fs;
use std::os::windows::fs::MetadataExt;
use std::path::{Component, Path, PathBuf};

use serde::{Deserialize, Serialize};
use windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT;

use crate::atomic_file;

pub const BINDING_SCHEMA: &str = "swawkit.project-binding/v1";
pub const SWAWKIT_HOME_PLACEHOLDER: &str = "${SWAWKIT_HOME}";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectBinding {
    configured_target_project_root: String,
    target_project_root: PathBuf,
}

impl ProjectBinding {
    pub fn configured_target_project_root(&self) -> &str {
        &self.configured_target_project_root
    }

    pub fn target_project_root(&self) -> &Path {
        &self.target_project_root
    }

    pub fn action_root(&self) -> PathBuf {
        self.target_project_root.join(".swaw")
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProjectBindingState {
    Missing { path: PathBuf },
    Invalid {
        path: PathBuf,
        configured_target_project_root: Option<String>,
        error: String,
    },
    Ready(ProjectBinding),
}

impl ProjectBindingState {
    pub fn ready(&self) -> Option<&ProjectBinding> {
        match self {
            Self::Ready(binding) => Some(binding),
            Self::Missing { .. } | Self::Invalid { .. } => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct ProjectBindingStore {
    swawkit_home: PathBuf,
    data_root: PathBuf,
}

impl ProjectBindingStore {
    pub fn new(swawkit_home: impl Into<PathBuf>, data_root: impl Into<PathBuf>) -> Self {
        Self {
            swawkit_home: swawkit_home.into(),
            data_root: data_root.into(),
        }
    }

    pub fn read(&self) -> ProjectBindingState {
        let path = self.path();
        match fs::symlink_metadata(&path) {
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return ProjectBindingState::Missing { path };
            }
            Err(error) => {
                return ProjectBindingState::Invalid {
                    path,
                    configured_target_project_root: None,
                    error: format!("cannot inspect project binding: {error}"),
                };
            }
        }
        let record = match read_record(&path) {
            Ok(record) => record,
            Err(error) => {
                return ProjectBindingState::Invalid {
                    path,
                    configured_target_project_root: None,
                    error: error.to_string(),
                };
            }
        };
        let configured_target_project_root = record.target_project_root.clone();
        let result = validate_record(record).and_then(|record| {
            resolve_target_project_root(&self.swawkit_home, &record.target_project_root).map(
                |target_project_root| ProjectBinding {
                    configured_target_project_root: record.target_project_root,
                    target_project_root,
                },
            )
        });
        match result {
            Ok(binding) => ProjectBindingState::Ready(binding),
            Err(error) => ProjectBindingState::Invalid {
                path,
                configured_target_project_root: Some(configured_target_project_root),
                error: error.to_string(),
            },
        }
    }

    pub fn save(&self, target_project_root: &str) -> Result<ProjectBinding, BindingError> {
        validate_data_root(&self.data_root)?;
        let resolved = resolve_target_project_root(&self.swawkit_home, target_project_root)?;
        let record = ProjectBindingRecord {
            schema: BINDING_SCHEMA.to_owned(),
            target_project_root: target_project_root.to_owned(),
        };
        let mut content = serde_json::to_string_pretty(&record).map_err(|error| {
            BindingError::new(format!("cannot serialize project binding: {error}"))
        })?;
        content.push('\n');
        let path = self.path();
        validate_publication_target(&path)?;
        atomic_file::publish(&path, content.as_bytes()).map_err(|error| {
            BindingError::new(format!(
                "cannot publish project binding '{}': {error}",
                path.display()
            ))
        })?;
        Ok(ProjectBinding {
            configured_target_project_root: target_project_root.to_owned(),
            target_project_root: resolved,
        })
    }

    pub fn path(&self) -> PathBuf {
        self.data_root.join("_binding.json")
    }
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ProjectBindingRecord {
    schema: String,
    target_project_root: String,
}

fn read_record(path: &Path) -> Result<ProjectBindingRecord, BindingError> {
    validate_publication_target(path)?;
    let content = fs::read_to_string(path).map_err(|error| {
        BindingError::new(format!(
            "cannot read project binding '{}': {error}",
            path.display()
        ))
    })?;
    serde_json::from_str(&content)
        .map_err(|error| BindingError::new(format!("invalid project binding JSON: {error}")))
}

fn validate_record(record: ProjectBindingRecord) -> Result<ProjectBindingRecord, BindingError> {
    if record.schema != BINDING_SCHEMA {
        return Err(BindingError::new(format!(
            "unsupported project binding schema '{}'",
            record.schema
        )));
    }
    if record.target_project_root.trim().is_empty() {
        return Err(BindingError::new(
            "required property 'targetProjectRoot' is missing",
        ));
    }
    Ok(record)
}

fn resolve_target_project_root(
    swawkit_home: &Path,
    configured: &str,
) -> Result<PathBuf, BindingError> {
    if configured.trim() != configured || configured.is_empty() {
        return Err(BindingError::new(
            "targetProjectRoot cannot be empty or have surrounding whitespace",
        ));
    }

    let path = if configured == SWAWKIT_HOME_PLACEHOLDER {
        swawkit_home.to_path_buf()
    } else if let Some(suffix) = configured.strip_prefix(SWAWKIT_HOME_PLACEHOLDER) {
        let Some(relative) = suffix.strip_prefix(['/', '\\']) else {
            return Err(BindingError::new(format!(
                "'{SWAWKIT_HOME_PLACEHOLDER}' must be followed by a path separator"
            )));
        };
        let relative = Path::new(relative);
        for component in relative.components() {
            if !matches!(component, Component::Normal(_) | Component::CurDir) {
                return Err(BindingError::new(
                    "targetProjectRoot cannot escape SWAWKIT_HOME",
                ));
            }
        }
        swawkit_home.join(relative)
    } else {
        if configured.contains("${") {
            return Err(BindingError::new(
                "targetProjectRoot contains an unsupported placeholder",
            ));
        }
        let path = PathBuf::from(configured);
        if !path.is_absolute() {
            return Err(BindingError::new(format!(
                "targetProjectRoot must be absolute or start with {SWAWKIT_HOME_PLACEHOLDER}"
            )));
        }
        path
    };

    let path = std::path::absolute(&path).map_err(|error| {
        BindingError::new(format!(
            "invalid targetProjectRoot '{}': {error}",
            path.display()
        ))
    })?;
    if !path.is_dir() {
        return Err(BindingError::new(format!(
            "target project directory does not exist: {}",
            path.display()
        )));
    }
    Ok(path)
}

fn validate_data_root(data_root: &Path) -> Result<(), BindingError> {
    let metadata = fs::symlink_metadata(data_root).map_err(|error| {
        BindingError::new(format!(
            "cannot inspect DataRoot '{}': {error}",
            data_root.display()
        ))
    })?;
    if !metadata.is_dir() || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(BindingError::new(format!(
            "project binding DataRoot must be a regular directory: {}",
            data_root.display()
        )));
    }
    Ok(())
}

fn validate_publication_target(path: &Path) -> Result<(), BindingError> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(BindingError::new(format!(
                "cannot inspect project binding '{}': {error}",
                path.display()
            )));
        }
    };
    if !metadata.is_file() || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(BindingError::new(format!(
            "project binding must be a regular file: {}",
            path.display()
        )));
    }
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BindingError {
    message: String,
}

impl BindingError {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl fmt::Display for BindingError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl Error for BindingError {}

#[cfg(test)]
mod tests;
