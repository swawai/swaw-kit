use std::collections::BTreeSet;
use std::error::Error;
use std::fmt;
use std::path::{Component, Path, PathBuf};

use crate::profile::ModuleMountProfile;

pub const SWAWKIT_HOME_PLACEHOLDER: &str = "${SWAWKIT_HOME}";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectBinding {
    target_project_root: PathBuf,
    external_module_mounts: Vec<ModuleMount>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModuleMount {
    namespace: String,
    root: PathBuf,
}

impl ModuleMount {
    pub fn namespace(&self) -> &str {
        &self.namespace
    }

    pub fn root(&self) -> &Path {
        &self.root
    }
}

impl ProjectBinding {
    pub(crate) fn resolve(
        swawkit_home: &Path,
        configured_target_project_root: &str,
        configured_module_mounts: &[ModuleMountProfile],
    ) -> Result<Self, BindingError> {
        let target_project_root = resolve_root(
            swawkit_home,
            configured_target_project_root,
            "targetProjectRoot",
        )?;
        let mut namespaces = BTreeSet::new();
        let mut external_module_mounts = Vec::new();
        for mount in configured_module_mounts {
            if !namespaces.insert(mount.namespace.as_str()) {
                return Err(BindingError::new(format!(
                    "duplicate module mount namespace '{}'",
                    mount.namespace
                )));
            }
            external_module_mounts.push(ModuleMount {
                namespace: mount.namespace.clone(),
                root: resolve_root(
                    swawkit_home,
                    &mount.root,
                    &format!("moduleMounts.{}.root", mount.namespace),
                )?,
            });
        }
        Ok(Self {
            target_project_root,
            external_module_mounts,
        })
    }

    pub fn target_project_root(&self) -> &Path {
        &self.target_project_root
    }

    pub fn project_module_root(&self) -> PathBuf {
        self.target_project_root.join(".swaw")
    }

    pub fn external_module_mounts(&self) -> &[ModuleMount] {
        &self.external_module_mounts
    }
}

fn resolve_root(
    swawkit_home: &Path,
    configured: &str,
    label: &str,
) -> Result<PathBuf, BindingError> {
    if configured.trim() != configured || configured.is_empty() {
        return Err(BindingError::new(format!(
            "{label} cannot be empty or have surrounding whitespace"
        )));
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
                return Err(BindingError::new(format!(
                    "{label} cannot escape SWAWKIT_HOME"
                )));
            }
        }
        swawkit_home.join(relative)
    } else {
        if configured.contains("${") {
            return Err(BindingError::new(format!(
                "{label} contains an unsupported placeholder"
            )));
        }
        let path = PathBuf::from(configured);
        if !path.is_absolute() {
            return Err(BindingError::new(format!(
                "{label} must be absolute or start with {SWAWKIT_HOME_PLACEHOLDER}"
            )));
        }
        path
    };

    let path = std::path::absolute(&path).map_err(|error| {
        BindingError::new(format!("invalid {label} '{}': {error}", path.display()))
    })?;
    if !path.is_dir() {
        return Err(BindingError::new(format!(
            "{label} directory does not exist: {}",
            path.display()
        )));
    }
    Ok(path)
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
