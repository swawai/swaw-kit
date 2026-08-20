use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use windows_sys::Win32::System::Com::CoCreateGuid;
use windows_sys::core::GUID;

use crate::atomic_file;

use super::settings::current_input_revision;
use super::storage::{
    ExclusiveFileLock, ensure_directory_chain, existing_directory_chain, read_replaceable_bounded,
    regular_file_or_missing,
};
use super::{PRODUCER_CONTRACT, PRODUCER_EXPORT};

mod invalidation;
mod migration;

pub(crate) use invalidation::begin_unavailable;
pub use migration::migrate_legacy_layout;

const STATE_SCHEMA: &str = "swawkit.command-provider-state/v2";
const MAX_STATE_BYTES: u64 = 16 * 1024;
const REVISION_PREFIX: &str = "sha256-";

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PublicationAttempt {
    input_revision: String,
    token: String,
}

impl PublicationAttempt {
    pub fn input_revision(&self) -> &str {
        &self.input_revision
    }

    pub fn token(&self) -> &str {
        &self.token
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ProviderState {
    schema: String,
    status: String,
    input_revision: String,
    token: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    exports: Option<Vec<ProviderExport>>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct ProviderExport {
    id: String,
    contract: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ReadyProviderState {
    input_revision: String,
    token: String,
}

impl ReadyProviderState {
    pub fn input_revision(&self) -> &str {
        &self.input_revision
    }

    pub fn token(&self) -> &str {
        &self.token
    }
}

pub fn read_ready(
    data_root: &Path,
    expected_input_revision: &str,
) -> Result<ReadyProviderState, String> {
    require_revision(expected_input_revision, "Dev Settings input revision")?;
    let setup = existing_directory_chain(
        data_root,
        &["modules", "system", "dev", "setup"],
        "development setup provider",
    )
    .map_err(|error| error.to_string())?;
    let state = read_state(&setup.join("_state.json"))?
        .ok_or_else(|| "the development setup provider state is missing".to_owned())?;
    if state.status != "ready"
        || state.input_revision != expected_input_revision
        || state.exports.as_deref() != Some(expected_exports().as_slice())
    {
        return Err(
            "the development setup provider is not ready for the current inputs".to_owned(),
        );
    }
    Ok(ReadyProviderState {
        input_revision: state.input_revision,
        token: state.token,
    })
}

pub struct SetupProvider {
    data_root: PathBuf,
    state_path: PathBuf,
    state_lock_path: PathBuf,
    input_revision: String,
}

impl SetupProvider {
    pub fn new(
        data_root: impl Into<PathBuf>,
        input_revision: impl Into<String>,
    ) -> Result<Self, String> {
        let data_root = data_root.into();
        migrate_legacy_layout(&data_root)?;
        let input_revision = input_revision.into();
        require_revision(&input_revision, "Dev Settings input revision")?;
        let setup = ensure_directory_chain(
            &data_root,
            &["modules", "system", "dev", "setup"],
            "development setup provider",
        )
        .map_err(|error| error.to_string())?;
        let locks = ensure_directory_chain(
            &data_root,
            &["modules", "system", "dev", "setup", "locks"],
            "development setup locks",
        )
        .map_err(|error| error.to_string())?;
        Ok(Self {
            data_root,
            state_path: setup.join("_state.json"),
            state_lock_path: locks.join("state.lock"),
            input_revision,
        })
    }

    pub fn start(&self) -> Result<PublicationAttempt, String> {
        let _lock = self.lock()?;
        self.require_current_settings()?;
        let attempt = PublicationAttempt {
            input_revision: self.input_revision.clone(),
            token: fresh_token()?,
        };
        self.publish(&ProviderState {
            schema: STATE_SCHEMA.to_owned(),
            status: "unavailable".to_owned(),
            input_revision: attempt.input_revision.clone(),
            token: attempt.token.clone(),
            exports: None,
        })?;
        Ok(attempt)
    }

    pub fn complete(&self, attempt: &PublicationAttempt) -> Result<(), String> {
        let _lock = self.lock()?;
        let current = self.read()?.ok_or_else(|| stale_error())?;
        if current.schema != STATE_SCHEMA
            || current.status != "unavailable"
            || current.input_revision != attempt.input_revision
            || current.token != attempt.token
            || current.exports.is_some()
        {
            return Err(stale_error());
        }
        self.publish(&ProviderState {
            schema: STATE_SCHEMA.to_owned(),
            status: "ready".to_owned(),
            input_revision: attempt.input_revision.clone(),
            token: attempt.token.clone(),
            exports: Some(expected_exports()),
        })
    }

    fn lock(&self) -> Result<ExclusiveFileLock, String> {
        ExclusiveFileLock::acquire(&self.state_lock_path, Duration::from_secs(60))
            .map_err(|error| format!("cannot acquire development provider state lock: {error}"))
    }

    fn require_current_settings(&self) -> Result<(), String> {
        if current_input_revision(&self.data_root)? != self.input_revision {
            return Err(
                "the Dev Settings changed while .dev/setup was starting; run the command again"
                    .to_owned(),
            );
        }
        Ok(())
    }

    fn read(&self) -> Result<Option<ProviderState>, String> {
        read_state(&self.state_path)
    }

    fn publish(&self, state: &ProviderState) -> Result<(), String> {
        write_state(&self.state_path, state)
    }
}

fn write_state(path: &Path, state: &ProviderState) -> Result<(), String> {
    regular_file_or_missing(path, "command provider state").map_err(|error| error.to_string())?;
    let mut content = serde_json::to_string_pretty(state)
        .map_err(|error| format!("cannot serialize command provider state: {error}"))?
        .replace('\n', "\r\n")
        .into_bytes();
    content.extend_from_slice(b"\r\n");
    atomic_file::publish(path, &content).map_err(|error| {
        format!(
            "cannot publish command provider state '{}': {error}",
            path.display()
        )
    })
}

fn read_state(path: &Path) -> Result<Option<ProviderState>, String> {
    if !regular_file_or_missing(path, "command provider state")
        .map_err(|error| error.to_string())?
    {
        return Ok(None);
    }
    let content = read_replaceable_bounded(path, "command provider state", MAX_STATE_BYTES)
        .map_err(|error| error.to_string())?;
    let value: Value = serde_json::from_slice(&content)
        .map_err(|error| format!("cannot parse command provider state: {error}"))?;
    validate_state_shape(&value)?;
    let state: ProviderState = serde_json::from_value(value)
        .map_err(|error| format!("cannot parse command provider state: {error}"))?;
    require_revision(&state.input_revision, "command provider input revision")?;
    if !is_lower_hex(&state.token, 32) {
        return Err("invalid command provider publication token".to_owned());
    }
    if state.status == "ready" && state.exports.as_deref() != Some(expected_exports().as_slice()) {
        return Err("invalid command provider exports".to_owned());
    }
    Ok(Some(state))
}

fn validate_state_shape(value: &Value) -> Result<(), String> {
    let object = value
        .as_object()
        .ok_or_else(|| "command provider state must be an object".to_owned())?;
    let status = object
        .get("status")
        .and_then(Value::as_str)
        .ok_or_else(|| "command provider state status is invalid".to_owned())?;
    let expected: &[&str] = match status {
        "unavailable" => &["schema", "status", "inputRevision", "token"],
        "ready" => &["schema", "status", "inputRevision", "token", "exports"],
        _ => return Err("command provider state status is invalid".to_owned()),
    };
    if object.len() != expected.len()
        || expected
            .iter()
            .filter(|name| **name != "exports")
            .any(|name| !object.get(*name).is_some_and(Value::is_string))
    {
        return Err("command provider state shape is invalid".to_owned());
    }
    if object["schema"] != STATE_SCHEMA {
        return Err("command provider state schema is invalid".to_owned());
    }
    Ok(())
}

fn expected_exports() -> Vec<ProviderExport> {
    vec![ProviderExport {
        id: PRODUCER_EXPORT.to_owned(),
        contract: PRODUCER_CONTRACT.to_owned(),
    }]
}

fn is_lower_hex(value: &str, length: usize) -> bool {
    value.len() == length
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn require_revision(value: &str, subject: &str) -> Result<(), String> {
    if value.len() == REVISION_PREFIX.len() + 64
        && value.starts_with(REVISION_PREFIX)
        && value[REVISION_PREFIX.len()..]
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        Ok(())
    } else {
        Err(format!("invalid {subject}"))
    }
}

fn stale_error() -> String {
    "the project development inputs changed while .dev/setup was running; the stale build was not published"
        .to_owned()
}

fn fresh_token() -> Result<String, String> {
    let mut guid = GUID::default();
    let result = unsafe { CoCreateGuid(&mut guid) };
    if result < 0 {
        return Err(format!(
            "cannot create provider token: HRESULT 0x{:08x}",
            result as u32
        ));
    }
    Ok(format!(
        "{:08x}{:04x}{:04x}{}",
        guid.data1,
        guid.data2,
        guid.data3,
        guid.data4
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>()
    ))
}

#[cfg(test)]
mod tests;
