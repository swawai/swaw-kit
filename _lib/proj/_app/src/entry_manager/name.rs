use std::path::PathBuf;

use crate::context::EntryContext;

use super::EntryManagerError;

pub(super) const MAX_ENTRY_NAME_BYTES: usize = 48;

#[derive(Debug, Clone)]
pub(super) struct EntryTarget {
    pub name: String,
    pub entry_file: PathBuf,
    pub data_root: PathBuf,
}

impl EntryTarget {
    pub fn parse(context: &EntryContext, name: &str) -> Result<Self, EntryManagerError> {
        validate_name(name)?;
        Ok(Self {
            name: name.to_owned(),
            entry_file: context.swawkit_home.join(format!("{name}.exe")),
            data_root: context
                .swawkit_home
                .join("data")
                .join(format!("proj.{name}")),
        })
    }
}

pub(super) fn validate_name(name: &str) -> Result<(), EntryManagerError> {
    if name.is_empty() || name.len() > MAX_ENTRY_NAME_BYTES {
        return Err(EntryManagerError::invalid_name(
            "Entry name must contain 1 to 48 ASCII bytes",
        ));
    }
    if name == "swawkit" {
        return Err(EntryManagerError::invalid_name(
            "Entry name 'swawkit' is reserved for the manager",
        ));
    }
    let bytes = name.as_bytes();
    if !bytes[0].is_ascii_lowercase()
        || !bytes[bytes.len() - 1].is_ascii_lowercase() && !bytes[bytes.len() - 1].is_ascii_digit()
        || bytes.windows(2).any(|pair| pair == b"--")
        || !bytes
            .iter()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || *byte == b'-')
    {
        return Err(EntryManagerError::invalid_name(
            "Entry name must be canonical lowercase ASCII lower-kebab",
        ));
    }
    if is_dos_device_name(name) {
        return Err(EntryManagerError::invalid_name(
            "Entry name cannot be a reserved Windows DOS device name",
        ));
    }
    Ok(())
}

fn is_dos_device_name(name: &str) -> bool {
    matches!(name, "con" | "prn" | "aux" | "nul")
        || matches!(name.as_bytes(), [b'c', b'o', b'm', b'1'..=b'9'])
        || matches!(name.as_bytes(), [b'l', b'p', b't', b'1'..=b'9'])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_only_bounded_lower_kebab_names() {
        for valid in ["a", "proj1", "project-one", "a1-b2", "con-safe"] {
            assert!(validate_name(valid).is_ok(), "{valid}");
        }
        for invalid in [
            "",
            "swawkit",
            "1project",
            "Project",
            "project_one",
            "-project",
            "project-",
            "project--one",
        ] {
            assert!(validate_name(invalid).is_err(), "{invalid}");
        }
        assert!(validate_name(&"a".repeat(48)).is_ok());
        assert!(validate_name(&"a".repeat(49)).is_err());
    }

    #[test]
    fn rejects_every_reserved_dos_device_stem() {
        for invalid in ["con", "prn", "aux", "nul"] {
            assert!(validate_name(invalid).is_err(), "{invalid}");
        }
        for number in 1..=9 {
            for prefix in ["com", "lpt"] {
                let invalid = format!("{prefix}{number}");
                assert!(validate_name(&invalid).is_err(), "{invalid}");
            }
        }
    }
}
