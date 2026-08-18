use std::collections::BTreeSet;
use std::path::Path;
use std::process::Command;

use serde::{Deserialize, Serialize};

use crate::catalog::{CatalogSnapshot, CommandNode, MODULE_CONTRACT_FILE};
use crate::command::{CommandError, CommandResult};

use super::storage::{hex_sha256, invalid, read_regular_file};

pub(super) const DESCRIPTION_ARGUMENT: &str = "--swawkit-describe";
pub(super) const DESCRIPTION_PROTOCOL: &str = "swawkit.native-command-description/v1";
pub(super) const RELEASE_FILE: &str = "swawkit.release.json";
pub(super) const RELEASE_PROTOCOL: &str = "swawkit.native-command-release/v1";
const EXECUTABLE_NAME: &str = "run.exe";
const MAX_DESCRIPTION_BYTES: usize = 64 * 1024;
const MAX_MANIFEST_BYTES: usize = 1024 * 1024;
pub(super) const MAX_RELEASE_BYTES: usize = 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub(super) struct SourceContract {
    pub(super) sha256: String,
    pub(super) commands: Vec<String>,
    pub(super) manifests: Vec<SourceManifest>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct SourceManifest {
    pub(super) address: String,
    pub(super) sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub(super) struct ReleaseManifest {
    pub(super) schema: String,
    pub(super) owner: String,
    pub(super) source: SourceContract,
    pub(super) executable: ExecutableArtifact,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct ExecutableArtifact {
    pub(super) name: String,
    pub(super) length: u64,
    pub(super) sha256: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct NativeDescription {
    schema: String,
    owner: String,
    commands: Vec<String>,
}

pub(super) fn source_contract(
    catalog: &CatalogSnapshot,
    owner: &CommandNode,
) -> Result<SourceContract, String> {
    let mut members = catalog
        .commands
        .iter()
        .filter(|command| {
            command.alias_of.is_none()
                && (command.address == owner.address
                    || command.native_owner.as_deref() == Some(owner.address.as_str()))
        })
        .collect::<Vec<_>>();
    members.sort_by(|left, right| left.address.cmp(&right.address));

    let commands = members
        .iter()
        .filter(|command| command.adapter.as_deref() == Some("delegate"))
        .map(|command| command.address.clone())
        .collect::<Vec<_>>();
    let mut manifests = Vec::with_capacity(members.len());
    for command in members {
        if command.entry.as_deref() != Some(MODULE_CONTRACT_FILE) {
            return Err(format!(
                "native release member '{}' has no canonical {MODULE_CONTRACT_FILE}",
                command.address
            ));
        }
        let path = command.directory.join(MODULE_CONTRACT_FILE);
        let bytes = read_regular_file(&path, "native command source manifest")
            .map_err(|error| error.to_string())?;
        if bytes.len() > MAX_MANIFEST_BYTES {
            return Err(format!(
                "native command source manifest exceeds {MAX_MANIFEST_BYTES} bytes: '{}'",
                path.display()
            ));
        }
        let value: serde_json::Value = serde_json::from_slice(&bytes).map_err(|error| {
            format!(
                "cannot parse native command source manifest '{}': {error}",
                path.display()
            )
        })?;
        let canonical = serde_json::to_vec(&value).map_err(|error| {
            format!(
                "cannot canonicalize native command source manifest '{}': {error}",
                path.display()
            )
        })?;
        manifests.push(SourceManifest {
            address: command.address.clone(),
            sha256: hex_sha256(&canonical),
        });
    }
    let identity = serde_json::to_vec(&manifests)
        .map_err(|error| format!("cannot serialize native source contract: {error}"))?;
    Ok(SourceContract {
        sha256: hex_sha256(&identity),
        commands,
        manifests,
    })
}

pub(super) fn validate_candidate(
    executable: &Path,
    owner: &CommandNode,
    source: &SourceContract,
) -> Result<(), String> {
    let mut command = Command::new(executable);
    command.arg(DESCRIPTION_ARGUMENT);
    let output = crate::development::process_probe::run(
        command,
        &format!("compiled native command '{}'", executable.display()),
    )?;
    if output.exit_code != 0 {
        return Err(format!(
            "compiled native command description failed with exit code {}: {}",
            output.exit_code, output.stderr
        ));
    }
    if output.stdout.len() > MAX_DESCRIPTION_BYTES {
        return Err(format!(
            "compiled native command description exceeds {MAX_DESCRIPTION_BYTES} bytes"
        ));
    }
    let description: NativeDescription = serde_json::from_str(&output.stdout).map_err(|error| {
        format!(
            "compiled native command returned an invalid {DESCRIPTION_PROTOCOL} document: {error}"
        )
    })?;
    if description.schema != DESCRIPTION_PROTOCOL {
        return Err(format!(
            "compiled native command description uses unsupported schema '{}'",
            description.schema
        ));
    }
    if description.owner != owner.address {
        return Err(format!(
            "compiled native command describes owner '{}'; expected '{}'",
            description.owner, owner.address
        ));
    }
    let described_count = description.commands.len();
    let described = description.commands.into_iter().collect::<BTreeSet<_>>();
    if described.len() != described_count
        || described.len() != source.commands.len()
        || described.iter().ne(source.commands.iter())
    {
        return Err(format!(
            "compiled native command ports do not match {MODULE_CONTRACT_FILE}: described=[{}], declared=[{}]",
            described.into_iter().collect::<Vec<_>>().join(", "),
            source.commands.join(", ")
        ));
    }
    Ok(())
}

pub(super) fn release_document(
    owner: &str,
    source: SourceContract,
    executable: &[u8],
) -> Result<Vec<u8>, String> {
    let manifest = ReleaseManifest {
        schema: RELEASE_PROTOCOL.to_owned(),
        owner: owner.to_owned(),
        source,
        executable: ExecutableArtifact {
            name: EXECUTABLE_NAME.to_owned(),
            length: executable.len() as u64,
            sha256: hex_sha256(executable),
        },
    };
    serde_json::to_vec(&manifest)
        .map_err(|error| format!("cannot serialize native release manifest: {error}"))
}

pub(super) fn validate_release(
    bytes: &[u8],
    expected_owner: &str,
    expected_source: &SourceContract,
) -> CommandResult<ReleaseManifest> {
    let manifest = parse_release(bytes)?;
    if manifest.schema != RELEASE_PROTOCOL {
        return invalid(format!(
            "unsupported native command release schema '{}'",
            manifest.schema
        ));
    }
    if manifest.owner != expected_owner {
        return invalid(format!(
            "native command release owner mismatch: selected='{}', expected='{expected_owner}'",
            manifest.owner
        ));
    }
    validate_source_contract(&manifest.source)?;
    if manifest.source != *expected_source {
        return invalid(format!(
            "native command source contract does not match the selected release: selected={}, current={}",
            manifest.source.sha256, expected_source.sha256
        ));
    }
    if manifest.executable.name != EXECUTABLE_NAME {
        return invalid(format!(
            "native command release executable must be named {EXECUTABLE_NAME}"
        ));
    }
    Ok(manifest)
}

pub(super) fn validate_artifact(
    manifest: &ReleaseManifest,
    executable: &[u8],
) -> CommandResult<()> {
    if manifest.executable.length != executable.len() as u64
        || manifest.executable.sha256 != hex_sha256(executable)
    {
        return invalid("native command executable does not match its release manifest".to_owned());
    }
    Ok(())
}

pub(super) fn validate_publication(release: &[u8], executable: &[u8]) -> Result<(), String> {
    let manifest = parse_release(release).map_err(|error| error.to_string())?;
    if manifest.schema != RELEASE_PROTOCOL || manifest.executable.name != EXECUTABLE_NAME {
        return Err(
            "native command release manifest has an invalid publication identity".to_owned(),
        );
    }
    validate_source_contract(&manifest.source).map_err(|error| error.to_string())?;
    validate_artifact(&manifest, executable).map_err(|error| error.to_string())
}

fn validate_source_contract(source: &SourceContract) -> CommandResult<()> {
    if source.commands.windows(2).any(|pair| pair[0] >= pair[1])
        || source
            .manifests
            .windows(2)
            .any(|pair| pair[0].address >= pair[1].address)
        || source.manifests.iter().any(|manifest| {
            manifest.sha256.len() != 64
                || !manifest
                    .sha256
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        })
    {
        return invalid("native command release has an invalid source contract".to_owned());
    }
    let source_identity = serde_json::to_vec(&source.manifests).map_err(|error| {
        CommandError::new(format!("cannot verify native source contract: {error}"))
    })?;
    if source.sha256 != hex_sha256(&source_identity) {
        return invalid("native command release has an invalid source contract digest".to_owned());
    }
    Ok(())
}

fn parse_release(bytes: &[u8]) -> CommandResult<ReleaseManifest> {
    serde_json::from_slice(bytes).map_err(|error| {
        CommandError::new(format!("invalid native command release manifest: {error}"))
    })
}
