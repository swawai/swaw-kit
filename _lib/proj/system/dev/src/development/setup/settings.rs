use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Serialize;
use swawkit_proj_protocol::{
    DevSettings, dev_settings_input_revision, parse_dev_settings, revision, validate_dev_settings,
};

use crate::atomic_file;

use super::provider::{begin_unavailable, migrate_legacy_layout};
use super::storage::{
    ExclusiveFileLock, ensure_directory_chain, read_replaceable_bounded, regular_directory,
    regular_file_or_missing,
};

pub const SETTINGS_DOCUMENT_PROTOCOL: &str = "swawkit.proj-dev-settings-state/v1";
const SETTINGS_FILE_NAME: &str = "_settings.json";
const MAX_SETTINGS_BYTES: u64 = 64 * 1024;
const SETUP_COMPONENTS: [&str; 4] = ["modules", "system", "dev", "setup"];

const SETTING_ADDRESSES: [&str; 10] = [
    ".dev/bun/mode",
    ".dev/bun/sha256",
    ".dev/bun/version",
    ".dev/msvc/channel",
    ".dev/msvc/mode",
    ".dev/pwsh/mode",
    ".dev/pwsh/sha256",
    ".dev/pwsh/version",
    ".dev/rust/mode",
    ".dev/rust/toolchain",
];

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DevSettingsSnapshot {
    settings: DevSettings,
    revision: String,
    input_revision: String,
    stored: bool,
    path: PathBuf,
}

impl DevSettingsSnapshot {
    pub fn settings(&self) -> &DevSettings {
        &self.settings
    }

    pub fn revision(&self) -> &str {
        &self.revision
    }

    pub fn input_revision(&self) -> &str {
        &self.input_revision
    }

    pub fn document(&self) -> DevSettingsDocument {
        DevSettingsDocument {
            protocol: SETTINGS_DOCUMENT_PROTOCOL,
            revision: self.revision.clone(),
            input_revision: self.input_revision.clone(),
            source: if self.stored { "stored" } else { "default" },
            path: self.path.display().to_string(),
            values: setting_values(&self.settings),
            settings: self.settings.clone(),
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DevSettingsDocument {
    pub protocol: &'static str,
    pub revision: String,
    pub input_revision: String,
    pub source: &'static str,
    pub path: String,
    pub values: BTreeMap<&'static str, String>,
    pub settings: DevSettings,
}

#[derive(Clone, Debug)]
pub struct DevSettingsStore {
    data_root: PathBuf,
}

impl DevSettingsStore {
    pub fn new(data_root: impl Into<PathBuf>) -> Self {
        Self {
            data_root: data_root.into(),
        }
    }

    pub fn snapshot(&self) -> Result<DevSettingsSnapshot, String> {
        read_snapshot(&self.data_root)
    }

    pub fn update_setting(
        &self,
        address: &str,
        value: String,
        expected_revision: Option<&str>,
    ) -> Result<DevSettingsSnapshot, String> {
        if !is_setting_address(address) {
            return Err(format!("unknown Dev Settings address '{address}'"));
        }
        migrate_legacy_layout(&self.data_root)?;
        let setup =
            ensure_directory_chain(&self.data_root, &SETUP_COMPONENTS, "Dev Settings directory")
                .map_err(|error| error.to_string())?;
        let locks = ensure_directory_chain(
            &self.data_root,
            &["modules", "system", "dev", "setup", "locks"],
            "Dev Settings lock directory",
        )
        .map_err(|error| error.to_string())?;
        let _settings_lock =
            ExclusiveFileLock::acquire(&locks.join("settings.lock"), Duration::from_secs(60))
                .map_err(|error| format!("cannot acquire Dev Settings lock: {error}"))?;

        let current = read_snapshot(&self.data_root)?;
        if expected_revision.is_some_and(|expected| expected != current.revision) {
            return Err(format!(
                "Dev Settings changed since revision '{}'; current revision is '{}'",
                expected_revision.unwrap_or_default(),
                current.revision
            ));
        }
        let mut settings = current.settings.clone();
        set_value(&mut settings, address, value)?;
        validate_dev_settings(&settings).map_err(|error| error.to_string())?;
        let content = serialize(&settings)?;
        let next = DevSettingsSnapshot {
            input_revision: dev_settings_input_revision(&settings)
                .map_err(|error| error.to_string())?,
            revision: revision(&content),
            settings,
            stored: true,
            path: setup.join(SETTINGS_FILE_NAME),
        };
        if current.stored && current.revision == next.revision {
            return Ok(current);
        }

        let invalidation = (current.input_revision != next.input_revision)
            .then(|| begin_unavailable(&self.data_root, &next.input_revision))
            .transpose()?;
        regular_file_or_missing(&next.path, "Dev Settings").map_err(|error| error.to_string())?;
        if let Err(error) = atomic_file::publish(&next.path, &content) {
            let publication_error = format!(
                "cannot publish Dev Settings '{}': {error}",
                next.path.display()
            );
            if let Some(invalidation) = invalidation {
                return match invalidation.rollback() {
                    Ok(()) => Err(publication_error),
                    Err(rollback) => Err(format!("{publication_error}; additionally, {rollback}")),
                };
            }
            return Err(publication_error);
        }
        if let Some(invalidation) = invalidation {
            invalidation.commit();
        }
        Ok(next)
    }
}

pub fn is_setting_address(address: &str) -> bool {
    SETTING_ADDRESSES.contains(&address)
}

pub fn setting_addresses() -> &'static [&'static str] {
    &SETTING_ADDRESSES
}

pub(crate) fn current_input_revision(data_root: &Path) -> Result<String, String> {
    Ok(read_snapshot(data_root)?.input_revision)
}

fn read_snapshot(data_root: &Path) -> Result<DevSettingsSnapshot, String> {
    let path = SETUP_COMPONENTS
        .iter()
        .fold(data_root.to_path_buf(), |path, component| {
            path.join(component)
        })
        .join(SETTINGS_FILE_NAME);
    if !settings_parent_exists(data_root)? {
        return default_snapshot(path);
    }
    if !regular_file_or_missing(&path, "Dev Settings").map_err(|error| error.to_string())? {
        return default_snapshot(path);
    }
    let content = read_replaceable_bounded(&path, "Dev Settings", MAX_SETTINGS_BYTES)
        .map_err(|error| error.to_string())?;
    let settings = parse_dev_settings(&content).map_err(|error| error.to_string())?;
    Ok(DevSettingsSnapshot {
        input_revision: dev_settings_input_revision(&settings)
            .map_err(|error| error.to_string())?,
        revision: revision(&content),
        settings,
        stored: true,
        path,
    })
}

fn default_snapshot(path: PathBuf) -> Result<DevSettingsSnapshot, String> {
    let settings = DevSettings::default();
    Ok(DevSettingsSnapshot {
        input_revision: dev_settings_input_revision(&settings)
            .map_err(|error| error.to_string())?,
        revision: "missing".to_owned(),
        settings,
        stored: false,
        path,
    })
}

fn settings_parent_exists(data_root: &Path) -> Result<bool, String> {
    regular_directory(data_root, "Entry DataRoot").map_err(|error| error.to_string())?;
    let mut path = data_root.to_path_buf();
    for component in SETUP_COMPONENTS {
        path.push(component);
        match fs::symlink_metadata(&path) {
            Ok(_) => regular_directory(&path, "Dev Settings directory")
                .map_err(|error| error.to_string())?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
            Err(error) => return Err(format!("cannot inspect Dev Settings directory: {error}")),
        }
    }
    Ok(true)
}

fn serialize(settings: &DevSettings) -> Result<Vec<u8>, String> {
    let mut content = serde_json::to_vec_pretty(settings)
        .map_err(|error| format!("cannot serialize Dev Settings: {error}"))?;
    content.push(b'\n');
    Ok(content)
}

fn set_value(settings: &mut DevSettings, address: &str, value: String) -> Result<(), String> {
    match address {
        ".dev/bun/mode" => settings.bun.mode = value,
        ".dev/bun/sha256" => settings.bun.sha256 = value,
        ".dev/bun/version" => settings.bun.version = value,
        ".dev/msvc/channel" => settings.msvc.channel = value,
        ".dev/msvc/mode" => settings.msvc.mode = value,
        ".dev/pwsh/mode" => settings.pwsh.mode = value,
        ".dev/pwsh/sha256" => settings.pwsh.sha256 = value,
        ".dev/pwsh/version" => settings.pwsh.version = value,
        ".dev/rust/mode" => settings.rust.mode = value,
        ".dev/rust/toolchain" => settings.rust.toolchain = value,
        _ => return Err(format!("unknown Dev Settings address '{address}'")),
    }
    Ok(())
}

fn setting_values(settings: &DevSettings) -> BTreeMap<&'static str, String> {
    BTreeMap::from([
        (".dev/bun/mode", settings.bun.mode.clone()),
        (".dev/bun/sha256", settings.bun.sha256.clone()),
        (".dev/bun/version", settings.bun.version.clone()),
        (".dev/msvc/channel", settings.msvc.channel.clone()),
        (".dev/msvc/mode", settings.msvc.mode.clone()),
        (".dev/pwsh/mode", settings.pwsh.mode.clone()),
        (".dev/pwsh/sha256", settings.pwsh.sha256.clone()),
        (".dev/pwsh/version", settings.pwsh.version.clone()),
        (".dev/rust/mode", settings.rust.mode.clone()),
        (".dev/rust/toolchain", settings.rust.toolchain.clone()),
    ])
}

#[cfg(test)]
mod tests;
