use std::error::Error;
use std::fmt;
use std::path::{Component, Path, PathBuf};

pub const SWAWKIT_HOME_PLACEHOLDER: &str = "${SWAWKIT_HOME}";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectBinding {
    project_root: PathBuf,
}

impl ProjectBinding {
    pub(crate) fn resolve(
        swawkit_home: &Path,
        configured_project_root: &str,
    ) -> Result<Self, BindingError> {
        let project_root = resolve_root(swawkit_home, configured_project_root, "projectRoot")?;
        Ok(Self { project_root })
    }

    pub fn project_root(&self) -> &Path {
        &self.project_root
    }

    pub fn project_module_root(&self) -> PathBuf {
        self.project_root.join(".swaw")
    }
}

fn resolve_root(
    swawkit_home: &Path,
    configured: &str,
    label: &str,
) -> Result<PathBuf, BindingError> {
    validate_project_root(configured, label)?;

    let path = if configured == SWAWKIT_HOME_PLACEHOLDER {
        swawkit_home.to_path_buf()
    } else if let Some(suffix) = configured.strip_prefix(SWAWKIT_HOME_PLACEHOLDER) {
        let relative = suffix
            .strip_prefix(['/', '\\'])
            .expect("validated SWAWKIT_HOME suffix has a separator");
        swawkit_home.join(relative)
    } else {
        PathBuf::from(configured)
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

pub(crate) fn validate_project_root(configured: &str, label: &str) -> Result<(), BindingError> {
    if configured.trim() != configured || configured.is_empty() {
        return Err(BindingError::new(format!(
            "{label} cannot be empty or have surrounding whitespace"
        )));
    }

    if configured == SWAWKIT_HOME_PLACEHOLDER {
        Ok(())
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
        Ok(())
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
        Ok(())
    }
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
