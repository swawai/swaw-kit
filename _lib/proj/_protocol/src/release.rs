use serde::{Deserialize, Serialize};

use crate::{CommandIdentity, ProtocolError, ProtocolResult, is_revision, is_sha256, sha256_hex};

pub const COMMAND_RELEASE_SCHEMA: &str = "swawkit.native-command-release/v3";
pub const COMMAND_EXECUTABLE_NAME: &str = "run.exe";

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CommandRelease {
    pub schema: String,
    pub owner: String,
    pub build_input_revision: String,
    pub execution_contract_revision: String,
    pub commands: Vec<String>,
    pub executable: ExecutableArtifact,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ExecutableArtifact {
    pub name: String,
    pub length: u64,
    pub sha256: String,
}

impl CommandRelease {
    pub fn new(
        owner: impl Into<String>,
        build_input_revision: impl Into<String>,
        execution_contract_revision: impl Into<String>,
        mut commands: Vec<String>,
        executable: &[u8],
    ) -> ProtocolResult<Self> {
        commands.sort();
        let release = Self {
            schema: COMMAND_RELEASE_SCHEMA.to_owned(),
            owner: owner.into(),
            build_input_revision: build_input_revision.into(),
            execution_contract_revision: execution_contract_revision.into(),
            commands,
            executable: ExecutableArtifact {
                name: COMMAND_EXECUTABLE_NAME.to_owned(),
                length: executable.len() as u64,
                sha256: sha256_hex(executable),
            },
        };
        validate_command_release(&release, &release.owner)?;
        if executable.is_empty() {
            return Err(ProtocolError::new("command executable cannot be empty"));
        }
        Ok(release)
    }
}

pub fn parse_command_release(bytes: &[u8]) -> ProtocolResult<CommandRelease> {
    serde_json::from_slice(bytes)
        .map_err(|error| ProtocolError::new(format!("invalid command release document: {error}")))
}

pub fn validate_command_release(
    release: &CommandRelease,
    expected_owner: &str,
) -> ProtocolResult<()> {
    if release.schema != COMMAND_RELEASE_SCHEMA {
        return Err(ProtocolError::new(format!(
            "unsupported command release schema '{}'; expected '{COMMAND_RELEASE_SCHEMA}'",
            release.schema
        )));
    }
    let owner = CommandIdentity::parse(expected_owner)?;
    if release.owner != expected_owner {
        return Err(ProtocolError::new(format!(
            "command release owner mismatch: selected='{}', expected='{expected_owner}'",
            release.owner
        )));
    }
    if !is_revision(&release.build_input_revision)
        || !is_revision(&release.execution_contract_revision)
        || release.commands.windows(2).any(|pair| pair[0] >= pair[1])
        || release.commands.iter().any(|address| {
            CommandIdentity::parse(address)
                .map_or(true, |command| !owner.is_true_ancestor_of(&command))
        })
        || release.executable.name != COMMAND_EXECUTABLE_NAME
        || release.executable.length == 0
        || !is_sha256(&release.executable.sha256)
    {
        return Err(ProtocolError::new(
            "command release document has invalid fields",
        ));
    }
    Ok(())
}

pub fn validate_command_artifact(
    release: &CommandRelease,
    executable: &[u8],
) -> ProtocolResult<()> {
    if release.executable.length != executable.len() as u64
        || release.executable.sha256 != sha256_hex(executable)
    {
        return Err(ProtocolError::new(
            "command executable does not match its release document",
        ));
    }
    Ok(())
}

pub fn command_release_document(release: &CommandRelease) -> ProtocolResult<Vec<u8>> {
    validate_command_release(release, &release.owner)?;
    serde_json::to_vec(release).map_err(|error| {
        ProtocolError::new(format!(
            "cannot serialize command release document: {error}"
        ))
    })
}

pub fn command_release_id(document: &[u8]) -> String {
    sha256_hex(document)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::revision;

    fn release() -> CommandRelease {
        CommandRelease::new(
            "swaw/context",
            revision(b"source"),
            revision(b"contract"),
            vec!["swaw/context/show".to_owned()],
            b"executable",
        )
        .unwrap()
    }

    #[test]
    fn release_round_trip_has_a_content_identity() {
        let release = release();
        let document = command_release_document(&release).unwrap();
        assert_eq!(parse_command_release(&document).unwrap(), release);
        assert!(is_sha256(&command_release_id(&document)));
    }

    #[test]
    fn old_v2_release_is_rejected_without_fallback() {
        let mut value = serde_json::to_value(release()).unwrap();
        value["schema"] = serde_json::Value::String("swawkit.native-command-release/v2".to_owned());
        let parsed = parse_command_release(&serde_json::to_vec(&value).unwrap()).unwrap();
        assert!(validate_command_release(&parsed, "swaw/context").is_err());
    }

    #[test]
    fn executable_integrity_is_exact() {
        let release = release();
        validate_command_artifact(&release, b"executable").unwrap();
        assert!(validate_command_artifact(&release, b"changed").is_err());
    }

    #[test]
    fn release_commands_must_be_true_owner_descendants() {
        assert!(
            CommandRelease::new(
                "swaw/context",
                revision(b"source"),
                revision(b"contract"),
                vec!["swaw/other".to_owned()],
                b"executable",
            )
            .is_err()
        );
    }

    #[test]
    fn system_release_uses_the_system_owner_identity() {
        let release = CommandRelease::new(
            ".context",
            revision(b"source"),
            revision(b"contract"),
            vec![".context/show".to_owned()],
            b"executable",
        )
        .unwrap();
        validate_command_release(&release, ".context").unwrap();
    }

    #[test]
    fn release_commands_cannot_cross_command_spaces() {
        assert!(
            CommandRelease::new(
                ".context",
                revision(b"source"),
                revision(b"contract"),
                vec!["swaw/context/show".to_owned()],
                b"executable",
            )
            .is_err()
        );
    }
}
