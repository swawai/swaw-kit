use std::collections::BTreeSet;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::{ProtocolError, ProtocolResult, is_revision};

pub const DEV_ENVIRONMENT_SCHEMA: &str = "swawkit.proj-dev-environment/v1";
pub const DEV_ENVIRONMENT_EXPORT_NAME: &str = "environment.json";
pub const DEV_SETUP_CONTRACT: &str = "swawkit.proj.dev-setup/v4";

const MAX_ENVIRONMENT_ITEMS: usize = 128;
const MAX_ENVIRONMENT_NAME_BYTES: usize = 128;
const MAX_ENVIRONMENT_VALUE_BYTES: usize = 32 * 1024;
const MAX_PATH_BYTES: usize = 32 * 1024;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DevEnvironmentExport {
    pub schema: String,
    pub input_revision: String,
    pub publication_token: String,
    pub variables: Vec<DevEnvironmentVariable>,
    pub paths: Vec<String>,
    pub bun_executable: Option<String>,
    pub pwsh_executable: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DevEnvironmentVariable {
    pub name: String,
    pub value: Option<String>,
}

pub fn parse_dev_environment(content: &[u8]) -> ProtocolResult<DevEnvironmentExport> {
    let document: DevEnvironmentExport = serde_json::from_slice(content).map_err(|error| {
        ProtocolError::new(format!("cannot parse Dev environment Export: {error}"))
    })?;
    validate_dev_environment(&document)?;
    Ok(document)
}

pub fn validate_dev_environment(document: &DevEnvironmentExport) -> ProtocolResult<()> {
    if document.schema != DEV_ENVIRONMENT_SCHEMA {
        return Err(ProtocolError::new(format!(
            "unsupported Dev environment schema '{}'; expected '{DEV_ENVIRONMENT_SCHEMA}'",
            document.schema
        )));
    }
    if !is_revision(&document.input_revision) {
        return Err(ProtocolError::new(
            "Dev environment inputRevision must be a sha256 revision",
        ));
    }
    if !is_lower_hex(&document.publication_token, 32) {
        return Err(ProtocolError::new(
            "Dev environment publicationToken must be 32 lowercase hexadecimal characters",
        ));
    }
    if document.variables.len() > MAX_ENVIRONMENT_ITEMS {
        return Err(ProtocolError::new("Dev environment has too many variables"));
    }
    if document.paths.len() > MAX_ENVIRONMENT_ITEMS {
        return Err(ProtocolError::new(
            "Dev environment has too many PATH entries",
        ));
    }
    let mut variables = BTreeSet::new();
    for variable in &document.variables {
        if !valid_environment_name(&variable.name) {
            return Err(ProtocolError::new(format!(
                "invalid Dev environment variable name '{}'",
                variable.name
            )));
        }
        if variable
            .value
            .as_ref()
            .is_some_and(|value| value.len() > MAX_ENVIRONMENT_VALUE_BYTES || value.contains('\0'))
        {
            return Err(ProtocolError::new(format!(
                "invalid Dev environment variable value for '{}'",
                variable.name
            )));
        }
        if !variables.insert(variable.name.to_ascii_lowercase()) {
            return Err(ProtocolError::new(format!(
                "duplicate Dev environment variable '{}'",
                variable.name
            )));
        }
    }
    let mut paths = BTreeSet::new();
    for path in &document.paths {
        validate_absolute_path(path, "PATH entry")?;
        if !paths.insert(path.to_ascii_lowercase()) {
            return Err(ProtocolError::new(format!(
                "duplicate Dev environment PATH entry '{path}'"
            )));
        }
    }
    for (label, executable) in [
        ("bunExecutable", document.bun_executable.as_deref()),
        ("pwshExecutable", document.pwsh_executable.as_deref()),
    ] {
        let Some(executable) = executable else {
            continue;
        };
        validate_absolute_path(executable, label)?;
        let parent = Path::new(executable).parent().ok_or_else(|| {
            ProtocolError::new(format!("Dev environment {label} has no parent directory"))
        })?;
        let parent = parent.to_string_lossy().to_ascii_lowercase();
        if !paths.contains(&parent) {
            return Err(ProtocolError::new(format!(
                "Dev environment {label} parent is absent from paths"
            )));
        }
    }
    Ok(())
}

fn validate_absolute_path(value: &str, label: &str) -> ProtocolResult<()> {
    if value.is_empty()
        || value.len() > MAX_PATH_BYTES
        || value.contains('\0')
        || !Path::new(value).is_absolute()
    {
        return Err(ProtocolError::new(format!(
            "Dev environment {label} must be an absolute path"
        )));
    }
    Ok(())
}

fn valid_environment_name(value: &str) -> bool {
    if value.len() > MAX_ENVIRONMENT_NAME_BYTES {
        return false;
    }
    let mut bytes = value.bytes();
    bytes
        .next()
        .is_some_and(|byte| byte.is_ascii_alphabetic() || byte == b'_')
        && bytes.all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
}

fn is_lower_hex(value: &str, length: usize) -> bool {
    value.len() == length
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid() -> DevEnvironmentExport {
        DevEnvironmentExport {
            schema: DEV_ENVIRONMENT_SCHEMA.to_owned(),
            input_revision: format!("sha256-{}", "a".repeat(64)),
            publication_token: "b".repeat(32),
            variables: vec![DevEnvironmentVariable {
                name: "RUSTC".to_owned(),
                value: Some(r"C:\Tools\rustc.exe".to_owned()),
            }],
            paths: vec![r"C:\Tools".to_owned()],
            bun_executable: Some(r"C:\Tools\bun.exe".to_owned()),
            pwsh_executable: None,
        }
    }

    #[test]
    fn environment_export_is_strict_and_round_trips() {
        let expected = valid();
        validate_dev_environment(&expected).unwrap();
        let encoded = serde_json::to_vec(&expected).unwrap();
        assert_eq!(parse_dev_environment(&encoded).unwrap(), expected);
    }

    #[test]
    fn environment_export_rejects_duplicate_names_and_unbound_executables() {
        let mut duplicate = valid();
        duplicate.variables.push(DevEnvironmentVariable {
            name: "rustc".to_owned(),
            value: None,
        });
        assert!(validate_dev_environment(&duplicate).is_err());

        let mut unbound = valid();
        unbound.bun_executable = Some(r"C:\Other\bun.exe".to_owned());
        assert!(validate_dev_environment(&unbound).is_err());
    }
}
