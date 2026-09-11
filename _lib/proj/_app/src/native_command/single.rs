use std::fs;
use std::path::{Path, PathBuf};

use swawkit_proj_protocol::{
    COMMAND_EXECUTABLE_NAME, command_release_id, parse_command_release, validate_command_artifact,
    validate_command_release,
};

use crate::command::{CommandError, CommandResult};

use super::storage::{
    checked_directory, invalid, is_reparse_point, read_regular_file, read_release_selector,
};

const RELEASES_DIRECTORY: &str = "releases";
const RELEASE_FILE: &str = "swawkit.release.json";
const MAX_RELEASE_BYTES: u64 = 1024 * 1024;
const MAX_EXECUTABLE_BYTES: u64 = 512 * 1024 * 1024;

pub(super) fn resolve(
    native_root: &Path,
    expected_owner: &str,
    expected_execution_contract_revision: &str,
    expected_commands: &[String],
) -> CommandResult<PathBuf> {
    let export =
        checked_directory(&native_root.join("export"), "native export").map_err(uninstantiated)?;
    let capability = checked_directory(&export.join("command"), "native command export")?;
    let selector = capability.join("current");
    let release_id = read_release_selector(&selector, "native command release selector")
        .map_err(uninstantiated)?;
    let releases = checked_directory(
        &capability.join(RELEASES_DIRECTORY),
        "native command releases",
    )?;
    let release = checked_directory(&releases.join(&release_id), "native command release")?;
    validate_release_membership(&release)?;
    let release_document = read_regular_file(
        &release.join(RELEASE_FILE),
        "native command release manifest",
        MAX_RELEASE_BYTES,
    )?;
    let actual_release_id = command_release_id(&release_document);
    if actual_release_id != release_id {
        return invalid(format!(
            "native command release manifest integrity check failed for '{}': selector={release_id}, manifest={actual_release_id}",
            release.display()
        ));
    }
    let manifest = parse_command_release(&release_document)
        .and_then(|manifest| {
            validate_command_release(&manifest, expected_owner)?;
            Ok(manifest)
        })
        .map_err(|error| CommandError::new(error.to_string()))?;
    if manifest.execution_contract_revision != expected_execution_contract_revision
        || manifest.commands != expected_commands
    {
        return invalid(format!(
            "native command execution contract does not match the selected release: selected={}, current={expected_execution_contract_revision}",
            manifest.execution_contract_revision
        ));
    }
    let executable = release.join(COMMAND_EXECUTABLE_NAME);
    let bytes = read_regular_file(
        &executable,
        "native command executable",
        MAX_EXECUTABLE_BYTES,
    )?;
    validate_command_artifact(&manifest, &bytes)
        .map_err(|error| CommandError::new(error.to_string()))?;
    Ok(executable)
}

fn validate_release_membership(root: &Path) -> CommandResult<()> {
    let entries = fs::read_dir(root).map_err(|error| {
        CommandError::new(format!(
            "cannot enumerate native command release '{}': {error}",
            root.display()
        ))
    })?;
    let mut members = Vec::with_capacity(2);
    for entry in entries {
        let entry = entry.map_err(|error| {
            CommandError::new(format!(
                "cannot enumerate native command release '{}': {error}",
                root.display()
            ))
        })?;
        if members.len() == 2 {
            return invalid(format!(
                "native command release has invalid membership: '{}'",
                root.display()
            ));
        }
        let path = entry.path();
        let metadata = fs::symlink_metadata(&path).map_err(|error| {
            CommandError::new(format!(
                "cannot inspect native command release member '{}': {error}",
                path.display()
            ))
        })?;
        if !metadata.is_file() || is_reparse_point(&metadata) {
            return invalid(format!(
                "native command release has an unsafe member: '{}'",
                path.display()
            ));
        }
        members.push(
            entry
                .file_name()
                .into_string()
                .map_err(|_| CommandError::new("native command release member is not Unicode"))?,
        );
    }
    members.sort();
    if members != [COMMAND_EXECUTABLE_NAME, RELEASE_FILE] {
        return invalid(format!(
            "native command release has invalid membership: '{}'",
            root.display()
        ));
    }
    Ok(())
}

fn uninstantiated(error: CommandError) -> CommandError {
    CommandError::new(format!(
        "{error}. the native owner has not been instantiated; publish its run.exe before execution"
    ))
}
