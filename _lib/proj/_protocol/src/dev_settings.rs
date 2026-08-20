use serde::{Deserialize, Serialize};

use crate::{ProtocolError, ProtocolResult, revision};

pub const DEV_SETTINGS_SCHEMA: &str = "swawkit.proj-dev-settings/v1";

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DevSettings {
    pub schema: String,
    pub bun: DevArchiveToolSettings,
    pub pwsh: DevArchiveToolSettings,
    pub msvc: DevMsvcSettings,
    pub rust: DevRustSettings,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DevArchiveToolSettings {
    pub mode: String,
    pub version: String,
    pub sha256: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DevMsvcSettings {
    pub mode: String,
    pub channel: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DevRustSettings {
    pub mode: String,
    pub toolchain: String,
    pub profile: String,
    pub host: String,
}

impl Default for DevSettings {
    fn default() -> Self {
        Self {
            schema: DEV_SETTINGS_SCHEMA.to_owned(),
            bun: DevArchiveToolSettings::managed("1.2.15"),
            pwsh: DevArchiveToolSettings::managed("latest"),
            msvc: DevMsvcSettings {
                mode: "managed".to_owned(),
                channel: "17".to_owned(),
            },
            rust: DevRustSettings {
                mode: "rustup".to_owned(),
                toolchain: "stable".to_owned(),
                profile: "minimal".to_owned(),
                host: "x86_64-pc-windows-msvc".to_owned(),
            },
        }
    }
}

impl DevArchiveToolSettings {
    fn managed(version: &str) -> Self {
        Self {
            mode: "managed".to_owned(),
            version: version.to_owned(),
            sha256: String::new(),
        }
    }
}

pub fn parse_dev_settings(content: &[u8]) -> ProtocolResult<DevSettings> {
    let settings: DevSettings = serde_json::from_slice(content)
        .map_err(|error| ProtocolError::new(format!("cannot parse Dev Settings: {error}")))?;
    validate_dev_settings(&settings)?;
    Ok(settings)
}

pub fn validate_dev_settings(settings: &DevSettings) -> ProtocolResult<()> {
    if settings.schema != DEV_SETTINGS_SCHEMA {
        return Err(ProtocolError::new(format!(
            "unsupported Dev Settings schema '{}'; expected '{DEV_SETTINGS_SCHEMA}'",
            settings.schema
        )));
    }
    validate_archive("bun", &settings.bun, false)?;
    validate_archive("pwsh", &settings.pwsh, true)?;
    allowed_mode("msvc", &settings.msvc.mode, &["managed", "disabled"])?;
    required_when_enabled(
        "msvc.channel",
        &settings.msvc.channel,
        settings.msvc.mode == "managed",
    )?;
    allowed_mode("rust", &settings.rust.mode, &["rustup", "disabled"])?;
    required_when_enabled(
        "rust.toolchain",
        &settings.rust.toolchain,
        settings.rust.mode == "rustup",
    )?;
    require_trimmed("rust.profile", &settings.rust.profile)?;
    require_trimmed("rust.host", &settings.rust.host)?;
    if settings.rust.profile != "minimal" {
        return Err(ProtocolError::new(
            "rust.profile must be 'minimal' in Dev Settings v1",
        ));
    }
    if settings.rust.host != "x86_64-pc-windows-msvc" {
        return Err(ProtocolError::new(
            "rust.host must be 'x86_64-pc-windows-msvc' in Dev Settings v1",
        ));
    }
    Ok(())
}

pub fn dev_settings_input_revision(settings: &DevSettings) -> ProtocolResult<String> {
    validate_dev_settings(settings)?;
    let normalized = NormalizedInputs {
        schema: DEV_SETTINGS_SCHEMA,
        bun: NormalizedArchive {
            mode: &settings.bun.mode,
            version: &settings.bun.version,
            sha256: settings.bun.sha256.to_ascii_lowercase(),
        },
        pwsh: NormalizedArchive {
            mode: &settings.pwsh.mode,
            version: &settings.pwsh.version,
            sha256: settings.pwsh.sha256.to_ascii_lowercase(),
        },
        msvc: &settings.msvc,
        rust: NormalizedRust {
            mode: &settings.rust.mode,
            toolchain: settings.rust.toolchain.to_ascii_lowercase(),
            profile: &settings.rust.profile,
            host: &settings.rust.host,
        },
    };
    let content = serde_json::to_vec(&normalized)
        .map_err(|error| ProtocolError::new(format!("cannot hash Dev Settings: {error}")))?;
    Ok(revision(&content))
}

#[derive(Serialize)]
struct NormalizedInputs<'a> {
    schema: &'static str,
    bun: NormalizedArchive<'a>,
    pwsh: NormalizedArchive<'a>,
    msvc: &'a DevMsvcSettings,
    rust: NormalizedRust<'a>,
}

#[derive(Serialize)]
struct NormalizedArchive<'a> {
    mode: &'a str,
    version: &'a str,
    sha256: String,
}

#[derive(Serialize)]
struct NormalizedRust<'a> {
    mode: &'a str,
    toolchain: String,
    profile: &'a str,
    host: &'a str,
}

fn validate_archive(
    name: &str,
    settings: &DevArchiveToolSettings,
    supports_system: bool,
) -> ProtocolResult<()> {
    let modes = if supports_system {
        &["managed", "system", "disabled"][..]
    } else {
        &["managed", "disabled"][..]
    };
    allowed_mode(name, &settings.mode, modes)?;
    required_when_enabled(
        &format!("{name}.version"),
        &settings.version,
        settings.mode == "managed",
    )?;
    optional_trimmed(&format!("{name}.sha256"), &settings.sha256)?;
    if !settings.sha256.is_empty()
        && (settings.sha256.len() != 64
            || !settings.sha256.bytes().all(|byte| byte.is_ascii_hexdigit()))
    {
        return Err(ProtocolError::new(format!(
            "{name}.sha256 must be empty or contain exactly 64 hexadecimal characters"
        )));
    }
    Ok(())
}

fn allowed_mode(path: &str, value: &str, allowed: &[&str]) -> ProtocolResult<()> {
    if allowed.contains(&value) {
        Ok(())
    } else {
        Err(ProtocolError::new(format!(
            "{path}.mode must be one of: {}",
            allowed.join(", ")
        )))
    }
}

fn required_when_enabled(path: &str, value: &str, enabled: bool) -> ProtocolResult<()> {
    if enabled {
        require_trimmed(path, value)
    } else {
        optional_trimmed(path, value)
    }
}

fn require_trimmed(path: &str, value: &str) -> ProtocolResult<()> {
    if value.is_empty() {
        return Err(ProtocolError::new(format!(
            "required Dev Settings property '{path}' is missing"
        )));
    }
    optional_trimmed(path, value)
}

fn optional_trimmed(path: &str, value: &str) -> ProtocolResult<()> {
    if value.trim() == value {
        Ok(())
    } else {
        Err(ProtocolError::new(format!(
            "Dev Settings property '{path}' cannot have surrounding whitespace"
        )))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_a_complete_strict_protocol_document() {
        let expected = DevSettings::default();
        validate_dev_settings(&expected).unwrap();
        let content = serde_json::to_vec(&expected).unwrap();
        assert_eq!(parse_dev_settings(&content).unwrap(), expected);
    }

    #[test]
    fn input_revision_normalizes_hashes_and_rust_toolchains() {
        let mut first = DevSettings::default();
        first.bun.sha256 = "A".repeat(64);
        first.rust.toolchain = "STABLE".to_owned();
        let mut second = first.clone();
        second.bun.sha256.make_ascii_lowercase();
        second.rust.toolchain.make_ascii_lowercase();
        assert_eq!(
            dev_settings_input_revision(&first).unwrap(),
            dev_settings_input_revision(&second).unwrap()
        );
    }

    #[test]
    fn profile_shape_and_unknown_fields_are_rejected() {
        let value = serde_json::json!({
            "schema": DEV_SETTINGS_SCHEMA,
            "development": {
                "bun": { "mode": "managed", "version": "1.2.15", "sha256": "" }
            }
        });
        assert!(parse_dev_settings(&serde_json::to_vec(&value).unwrap()).is_err());
        let mut value = serde_json::to_value(DevSettings::default()).unwrap();
        value
            .as_object_mut()
            .unwrap()
            .insert("legacy".to_owned(), true.into());
        assert!(parse_dev_settings(&serde_json::to_vec(&value).unwrap()).is_err());
    }
}
