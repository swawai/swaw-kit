use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use crate::{CommandIdentity, ProtocolError, ProtocolResult};

pub const MAX_COMMAND_REQUIREMENTS: usize = 64;
pub const MAX_COMMAND_PROVISIONS: usize = 64;

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct CommandRequirement {
    pub provider: String,
    pub export: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct CommandProvision {
    pub id: String,
}

pub fn validate_command_requirements(values: &[CommandRequirement]) -> ProtocolResult<()> {
    if values.len() > MAX_COMMAND_REQUIREMENTS {
        return Err(ProtocolError::new(format!(
            "command requirements cannot contain more than {MAX_COMMAND_REQUIREMENTS} items"
        )));
    }
    let mut seen = BTreeSet::new();
    for value in values {
        if CommandIdentity::parse(&value.provider).is_err()
            || !valid_capability_name(&value.export)
            || !seen.insert((&value.provider, &value.export))
        {
            return Err(ProtocolError::new(
                "invalid or duplicate command requirement provider/export",
            ));
        }
    }
    Ok(())
}

pub fn validate_command_provisions(values: &[CommandProvision]) -> ProtocolResult<()> {
    if values.len() > MAX_COMMAND_PROVISIONS {
        return Err(ProtocolError::new(format!(
            "command provisions cannot contain more than {MAX_COMMAND_PROVISIONS} items"
        )));
    }
    let mut seen = BTreeSet::new();
    for value in values {
        if !valid_capability_name(&value.id) || !seen.insert(&value.id) {
            return Err(ProtocolError::new(
                "invalid or duplicate command provision id",
            ));
        }
    }
    Ok(())
}

fn valid_capability_name(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 32
        && value.bytes().enumerate().all(|(index, byte)| {
            byte.is_ascii_lowercase() || (index > 0 && (byte.is_ascii_digit() || byte == b'-'))
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capability_identity_is_unique_and_command_scoped() {
        let requirements = vec![
            CommandRequirement {
                provider: ".dev/setup".to_owned(),
                export: "environment".to_owned(),
            },
            CommandRequirement {
                provider: ".dev/setup".to_owned(),
                export: "environment".to_owned(),
            },
        ];
        assert!(validate_command_requirements(&requirements).is_err());
        let provisions = vec![
            CommandProvision {
                id: "artifact".to_owned(),
            },
            CommandProvision {
                id: "artifact".to_owned(),
            },
        ];
        assert!(validate_command_provisions(&provisions).is_err());
    }
}
