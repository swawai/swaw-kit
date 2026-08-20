use std::fmt;

use swawkit_proj_protocol::{DevArchiveToolSettings, DevSettings};

use crate::development::ArchiveToolContract;
use crate::development::archive_tool::ArchiveToolRequest;
use crate::development::msvc::MsvcDefinition;
use crate::development::rust::RustDefinition;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DeclarationSnapshot {
    settings: DevSettings,
}

impl DeclarationSnapshot {
    pub fn archive_settings(
        &self,
        tool: &ArchiveToolContract,
    ) -> Result<&DevArchiveToolSettings, DeclarationError> {
        match tool.name {
            "bun" => Ok(&self.settings.bun),
            "pwsh" => Ok(&self.settings.pwsh),
            _ => Err(DeclarationError(format!(
                "archive tool '{}' is absent from Dev Settings",
                tool.name
            ))),
        }
    }

    pub fn archive_request(
        &self,
        tool: &ArchiveToolContract,
    ) -> Result<Option<ArchiveToolRequest>, DeclarationError> {
        let settings = self.archive_settings(tool)?;
        if settings.mode == "disabled" {
            return Ok(None);
        }
        if tool.name == "pwsh" && settings.mode == "system" {
            return Ok(None);
        }
        if settings.mode != "managed" {
            let expected = if tool.name == "pwsh" {
                "'managed', 'system', or 'disabled'"
            } else {
                "'managed' or 'disabled'"
            };
            return Err(DeclarationError(format!(
                "unsupported {} value '{}'; expected {expected}",
                tool.setting_address("mode"),
                settings.mode,
            )));
        }
        if settings.version.is_empty() {
            return Err(DeclarationError(format!(
                "enabled {} must declare {}",
                tool.display_name,
                tool.setting_address("version")
            )));
        }
        ArchiveToolRequest::new(tool, &settings.version, &settings.sha256)
            .map(Some)
            .map_err(|error| DeclarationError(error.to_string()))
    }

    pub fn msvc_definition(&self) -> Result<Option<MsvcDefinition>, DeclarationError> {
        let settings = &self.settings.msvc;
        if settings.mode == "disabled" {
            return Ok(None);
        }
        if settings.mode != "managed" {
            return Err(DeclarationError(format!(
                "unsupported .dev/msvc/mode value '{}'; expected 'managed' or 'disabled'",
                settings.mode
            )));
        }
        MsvcDefinition::new(&settings.channel)
            .map(Some)
            .map_err(|error| DeclarationError(error.to_string()))
    }

    pub fn rust_definition(&self) -> Result<Option<RustDefinition>, DeclarationError> {
        let settings = &self.settings.rust;
        if settings.mode == "disabled" {
            return Ok(None);
        }
        if settings.mode != "rustup" {
            return Err(DeclarationError(format!(
                "unsupported .dev/rust/mode value '{}'; expected 'rustup' or 'disabled'",
                settings.mode
            )));
        }
        RustDefinition::new(&settings.toolchain, &settings.profile, &settings.host)
            .map(Some)
            .map_err(|error| DeclarationError(error.to_string()))
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DeclarationError(String);

impl fmt::Display for DeclarationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for DeclarationError {}

pub fn snapshot_from_settings(settings: &DevSettings) -> DeclarationSnapshot {
    DeclarationSnapshot {
        settings: settings.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn disabled_settings() -> DevSettings {
        let mut settings = DevSettings::default();
        settings.bun.mode = "disabled".to_owned();
        settings.msvc.mode = "disabled".to_owned();
        settings.pwsh.mode = "disabled".to_owned();
        settings.rust.mode = "disabled".to_owned();
        settings
    }

    #[test]
    fn snapshot_owns_the_typed_settings() {
        let settings = DevSettings::default();
        let snapshot = snapshot_from_settings(&settings);

        assert_eq!(
            snapshot.archive_settings(&crate::development::BUN).unwrap(),
            &settings.bun
        );
    }

    #[test]
    fn archive_requests_are_typed() {
        let mut settings = disabled_settings();
        settings.bun.mode = "managed".to_owned();
        settings.bun.version = "1.2.15".to_owned();
        let snapshot = snapshot_from_settings(&settings);

        assert_eq!(
            snapshot
                .archive_request(&crate::development::BUN)
                .unwrap()
                .unwrap()
                .requested(),
            "1.2.15"
        );
    }

    #[test]
    fn system_powershell_is_enabled_without_an_archive_request() {
        let mut settings = disabled_settings();
        settings.pwsh.mode = "system".to_owned();
        let snapshot = snapshot_from_settings(&settings);

        assert!(
            snapshot
                .archive_request(&crate::development::PWSH)
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn msvc_declarations_are_typed() {
        let snapshot = snapshot_from_settings(&DevSettings::default());

        assert_eq!(snapshot.msvc_definition().unwrap().unwrap().channel(), "17");
    }

    #[test]
    fn rust_declarations_share_the_domain_definition() {
        let snapshot = snapshot_from_settings(&DevSettings::default());

        let definition = snapshot.rust_definition().unwrap().unwrap();

        assert_eq!(definition.toolchain(), "stable");
        assert_eq!(definition.toolchain_name(), "stable-x86_64-pc-windows-msvc");
    }
}
