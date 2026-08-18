use std::env;
use std::ffi::OsString;
use std::path::PathBuf;

use crate::error::{ContextError, ContextResult};
use crate::store::ContextStore;

const COMMAND_OWNER_ADDRESS_ENV: &str = "SWAWKIT_PROJ_CORE_COMMAND_OWNER_ADDRESS";
const COMMAND_OWNER_DATA_ROOT_ENV: &str = "SWAWKIT_PROJ_CORE_COMMAND_OWNER_DATA_ROOT";
const DATA_ROOT_ENV: &str = "SWAWKIT_PROJ_DATA_ROOT";
const LANGUAGE_ENV: &str = "SWAWKIT_PROJ_LANGUAGE";

pub(crate) struct ContextRuntime {
    pub(crate) store: ContextStore,
    pub(crate) language: Language,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Language {
    ZhCn,
    En,
}

impl ContextRuntime {
    pub(crate) fn from_environment() -> ContextResult<Self> {
        let owner_address = env::var(COMMAND_OWNER_ADDRESS_ENV).map_err(|_| {
            ContextError::new(format!(
                "Context command environment is missing {COMMAND_OWNER_ADDRESS_ENV}"
            ))
        })?;
        if owner_address != "swaw/context" {
            return Err(ContextError::new(format!(
                "Context executable cannot serve native owner '{owner_address}'"
            )));
        }
        let module_data_root = required_absolute_directory(COMMAND_OWNER_DATA_ROOT_ENV)?;
        let data_root = required_absolute_directory(DATA_ROOT_ENV)?;
        let language = match env::var(LANGUAGE_ENV).as_deref() {
            Ok("en") => Language::En,
            _ => Language::ZhCn,
        };
        Ok(Self {
            store: ContextStore::open(data_root, module_data_root)?,
            language,
        })
    }
}

fn required_absolute_directory(name: &str) -> ContextResult<PathBuf> {
    let path = required_absolute_path(name)?;
    if path.is_dir() {
        Ok(path)
    } else {
        Err(ContextError::new(format!(
            "Context command environment {name} is not a directory: {}",
            path.display()
        )))
    }
}

fn required_absolute_path(name: &str) -> ContextResult<PathBuf> {
    let value: OsString = env::var_os(name)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            ContextError::new(format!("Context command environment is missing {name}"))
        })?;
    let path = PathBuf::from(value);
    if path.is_absolute() {
        Ok(path)
    } else {
        Err(ContextError::new(format!(
            "Context command environment {name} must be absolute"
        )))
    }
}
