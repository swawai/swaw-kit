use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use crate::{CommandIdentity, ProtocolError, ProtocolResult};

pub const COMMAND_MODULE_SCHEMA: &str = "swawkit.command-module/v11";
pub const MAX_MODULE_REQUIREMENTS: usize = 64;
pub const MAX_MODULE_PROVISIONS: usize = 64;

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ModuleRequirement {
    pub provider: String,
    pub export: String,
    pub contract: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ModuleProvision {
    pub id: String,
    pub contract: String,
}

pub fn valid_command_segment(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value.bytes().enumerate().all(|(index, byte)| {
            byte.is_ascii_lowercase() || (index > 0 && (byte.is_ascii_digit() || byte == b'-'))
        })
        && !matches!(
            value,
            "con"
                | "prn"
                | "aux"
                | "nul"
                | "com1"
                | "com2"
                | "com3"
                | "com4"
                | "com5"
                | "com6"
                | "com7"
                | "com8"
                | "com9"
                | "lpt1"
                | "lpt2"
                | "lpt3"
                | "lpt4"
                | "lpt5"
                | "lpt6"
                | "lpt7"
                | "lpt8"
                | "lpt9"
        )
}

pub fn valid_module_namespace(value: &str) -> bool {
    valid_command_segment(value) && !matches!(value, "system" | "module")
}

pub fn validate_command_address(value: &str) -> ProtocolResult<()> {
    CommandIdentity::parse(value).map(|_| ())
}

pub fn valid_provider_address(value: &str) -> bool {
    CommandIdentity::parse(value).is_ok()
}

pub fn valid_module_token(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 32
        && value.bytes().enumerate().all(|(index, byte)| {
            byte.is_ascii_lowercase() || (index > 0 && (byte.is_ascii_digit() || byte == b'-'))
        })
}

pub fn valid_module_contract(value: &str) -> bool {
    (1..=128).contains(&value.len())
        && value
            .as_bytes()
            .first()
            .is_some_and(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
        && value.bytes().all(|byte| {
            byte.is_ascii_lowercase()
                || byte.is_ascii_digit()
                || matches!(byte, b'.' | b'_' | b'/' | b'-')
        })
}

pub fn validate_module_requirements(values: &[ModuleRequirement]) -> ProtocolResult<()> {
    if values.len() > MAX_MODULE_REQUIREMENTS {
        return Err(ProtocolError::new(format!(
            "module requirements cannot contain more than {MAX_MODULE_REQUIREMENTS} items"
        )));
    }
    let mut seen = BTreeSet::new();
    for value in values {
        if !valid_provider_address(&value.provider)
            || !valid_module_token(&value.export)
            || !valid_module_contract(&value.contract)
            || !seen.insert((&value.provider, &value.export))
        {
            return Err(ProtocolError::new(
                "invalid or duplicate module requirement provider/export",
            ));
        }
    }
    Ok(())
}

pub fn validate_module_provisions(values: &[ModuleProvision]) -> ProtocolResult<()> {
    if values.len() > MAX_MODULE_PROVISIONS {
        return Err(ProtocolError::new(format!(
            "module provisions cannot contain more than {MAX_MODULE_PROVISIONS} items"
        )));
    }
    let mut seen = BTreeSet::new();
    for value in values {
        if !valid_module_token(&value.id)
            || !valid_module_contract(&value.contract)
            || !seen.insert(&value.id)
        {
            return Err(ProtocolError::new(
                "invalid or duplicate module provision id",
            ));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_identity_matches_portable_catalog_names() {
        for valid in [
            ".context",
            ".context/add",
            "swaw/context",
            "user-custom/build-/app2",
        ] {
            validate_command_address(valid).unwrap();
        }
        for invalid in [
            "",
            ".",
            "swaw",
            "system/help",
            "2swaw/context",
            "swaw/con",
            "swaw/-context",
        ] {
            assert!(validate_command_address(invalid).is_err(), "{invalid}");
        }
    }

    #[test]
    fn provider_addresses_cover_system_and_module_commands() {
        for valid in [".dev/setup", ".dev/rust/setup", "project/build/app"] {
            assert!(valid_provider_address(valid), "{valid}");
        }
        for invalid in ["", ".", "..entry", "Dev/setup", ".dev//setup", "build"] {
            assert!(!valid_provider_address(invalid), "{invalid}");
        }
    }

    #[test]
    fn requirement_and_provision_identity_ignores_contract_version() {
        let requirements = vec![
            ModuleRequirement {
                provider: ".dev/setup".to_owned(),
                export: "environment".to_owned(),
                contract: "contract/v1".to_owned(),
            },
            ModuleRequirement {
                provider: ".dev/setup".to_owned(),
                export: "environment".to_owned(),
                contract: "contract/v2".to_owned(),
            },
        ];
        assert!(validate_module_requirements(&requirements).is_err());
        let provisions = vec![
            ModuleProvision {
                id: "artifact".to_owned(),
                contract: "contract/v1".to_owned(),
            },
            ModuleProvision {
                id: "artifact".to_owned(),
                contract: "contract/v2".to_owned(),
            },
        ];
        assert!(validate_module_provisions(&provisions).is_err());
    }
}
