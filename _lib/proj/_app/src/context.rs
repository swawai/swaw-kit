use std::env;
use std::error::Error;
use std::ffi::OsString;
use std::fmt;
use std::path::{Path, PathBuf};

const PROTOCOL_ENV: &str = "SWAWKIT_PROJ_PROTOCOL";
const PROJ_HOME_ENV: &str = "SWAWKIT_PROJ_HOME";
const PROJECT_ROOT_ENV: &str = "SWAWKIT_PROJ_DIR";
const ACTION_ROOT_ENV: &str = "SWAWKIT_PROJ_ACTION_ROOT";
const ENTRY_NAME_ENV: &str = "SWAWKIT_PROJ_ENTRY_COMMAND";

#[derive(Debug, Clone)]
pub struct AppContext {
    pub proj_home: PathBuf,
    pub project_root: PathBuf,
    pub action_root: PathBuf,
    pub entry_name: String,
}

impl AppContext {
    pub fn from_env() -> Result<Self, ContextError> {
        Self::from_lookup(|name| env::var_os(name))
    }

    pub fn kernel_root(&self) -> PathBuf {
        self.proj_home.join("_lib").join("proj")
    }

    fn from_lookup(mut lookup: impl FnMut(&str) -> Option<OsString>) -> Result<Self, ContextError> {
        let protocol = required_text(&mut lookup, PROTOCOL_ENV)?;
        if protocol != "1" {
            return Err(ContextError::new(format!(
                "unsupported {PROTOCOL_ENV} value '{protocol}'; expected '1'"
            )));
        }

        let proj_home = required_path(&mut lookup, PROJ_HOME_ENV)?;
        if !proj_home.is_dir() {
            return Err(ContextError::new(format!(
                "declared Swaw Kit Proj home does not exist: {}",
                proj_home.display()
            )));
        }

        let project_root = required_path(&mut lookup, PROJECT_ROOT_ENV)?;
        if !project_root.is_dir() {
            return Err(ContextError::new(format!(
                "declared project directory does not exist: {}",
                project_root.display()
            )));
        }

        let action_root = required_path(&mut lookup, ACTION_ROOT_ENV)?;
        let entry_name = required_text(&mut lookup, ENTRY_NAME_ENV)?;

        Ok(Self {
            proj_home,
            project_root,
            action_root,
            entry_name,
        })
    }
}

fn required_text(
    lookup: &mut impl FnMut(&str) -> Option<OsString>,
    name: &'static str,
) -> Result<String, ContextError> {
    let value = lookup(name).ok_or_else(|| {
        ContextError::new(format!(
            "required project declaration is missing: {name}"
        ))
    })?;
    let value = value.into_string().map_err(|_| {
        ContextError::new(format!(
            "project declaration {name} is not valid Unicode"
        ))
    })?;
    if value.trim().is_empty() {
        return Err(ContextError::new(format!(
            "required project declaration is missing: {name}"
        )));
    }
    Ok(value)
}

fn required_path(
    lookup: &mut impl FnMut(&str) -> Option<OsString>,
    name: &'static str,
) -> Result<PathBuf, ContextError> {
    let value = required_text(lookup, name)?;
    let path = Path::new(&value);
    if !path.is_absolute() {
        return Err(ContextError::new(format!(
            "project path declaration {name} must be absolute: {value}"
        )));
    }
    std::path::absolute(path).map_err(|error| {
        ContextError::new(format!(
            "invalid project path declaration {name}='{value}': {error}"
        ))
    })
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContextError {
    message: String,
}

impl ContextError {
    fn new(message: String) -> Self {
        Self { message }
    }
}

impl fmt::Display for ContextError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl Error for ContextError {}
