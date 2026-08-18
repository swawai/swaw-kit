use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use swawkit_proj_protocol::{
    CommandIdentity, CommandModuleExecution, CommandModuleManifest, CommandModuleSubjectRef,
    CommandSpace, ExecutionContract, ExecutionContractCommand, ExecutionSemantics,
    parse_command_module, valid_command_segment,
};

use crate::filesystem::{is_reparse, read_regular_file, regular_directory};

mod local_entry;

pub(crate) const MODULE_MANIFEST: &str = "swawkit.module.json";
const MAX_MANIFEST_BYTES: u64 = 1024 * 1024;
const MAX_MANIFESTS: usize = 4096;
const MAX_SUBTREE_ENTRIES: usize = 32_768;

pub(crate) struct NativeDomain {
    pub(crate) requested_address: String,
    pub(crate) owner_address: String,
    pub(crate) owner_identity: CommandIdentity,
    pub(crate) owner_directory: PathBuf,
    pub(crate) nested_owner_directories: Vec<PathBuf>,
    pub(crate) execution_contract: ExecutionContract,
}

impl NativeDomain {
    pub(crate) fn commands(&self) -> Vec<String> {
        self.execution_contract.delegated_commands()
    }

    pub(crate) fn execution_contract_revision(&self) -> Result<String, String> {
        self.execution_contract
            .revision()
            .map_err(|error| error.to_string())
    }
}

pub(crate) fn discover_native_domain(
    system_root: &Path,
    module_roots: &BTreeMap<String, PathBuf>,
    requested: &str,
) -> Result<NativeDomain, String> {
    let requested_identity =
        CommandIdentity::parse(requested).map_err(|error| error.to_string())?;
    let root = command_source_root(system_root, module_roots, &requested_identity)?;
    let requested_directory = canonical_directory(
        root,
        requested_identity.path(),
        "command source root",
        "command source directory",
    )?;
    let requested_manifest = read_manifest_in(&requested_directory)?;
    let owner_identity = match requested_manifest.execution {
        Some(CommandModuleExecution::Native) => requested_identity.clone(),
        Some(CommandModuleExecution::Delegate { owner }) => {
            let owner = command_reference_identity(&owner)?;
            if !owner.is_true_ancestor_of(&requested_identity) {
                return Err(format!(
                    "delegate '{requested}' must name a true ancestor owner in the same command space"
                ));
            }
            owner
        }
        _ => {
            return Err(format!(
                "command '{requested}' is not a native owner or delegated port"
            ));
        }
    };
    let owner_address = owner_identity.address();
    let owner_root = command_source_root(system_root, module_roots, &owner_identity)?;
    let owner_directory = canonical_directory(
        owner_root,
        owner_identity.path(),
        "command source root",
        "native owner source directory",
    )?;
    let owner_manifest = read_manifest_in(&owner_directory)?;
    if !matches!(
        owner_manifest.execution,
        Some(CommandModuleExecution::Native)
    ) {
        return Err(format!(
            "declared native owner '{owner_address}' does not use execution.native"
        ));
    }

    let mut commands = vec![contract_command(
        owner_address.clone(),
        ExecutionSemantics::Native,
        owner_manifest,
    )];
    let mut nested_owner_directories = Vec::new();
    collect_delegates(
        owner_root,
        &owner_identity,
        &owner_directory,
        &mut commands,
        &mut nested_owner_directories,
    )?;
    let execution_contract = ExecutionContract::new(owner_address.clone(), commands)
        .map_err(|error| format!("invalid native execution contract: {error}"))?;
    Ok(NativeDomain {
        requested_address: requested.to_owned(),
        owner_address,
        owner_identity,
        owner_directory,
        nested_owner_directories,
        execution_contract,
    })
}

fn collect_delegates(
    command_root: &Path,
    owner: &CommandIdentity,
    owner_directory: &Path,
    commands: &mut Vec<ExecutionContractCommand>,
    nested_owner_directories: &mut Vec<PathBuf>,
) -> Result<(), String> {
    let mut pending = vec![owner_directory.to_path_buf()];
    let mut manifest_count = 0_usize;
    let mut entry_count = 0_usize;
    while let Some(directory) = pending.pop() {
        regular_directory(&directory, "native owner subtree")?;
        let entries = fs::read_dir(&directory)
            .map_err(|error| format!("cannot enumerate '{}': {error}", directory.display()))?;
        for entry in entries {
            let entry = entry
                .map_err(|error| format!("cannot enumerate '{}': {error}", directory.display()))?;
            entry_count += 1;
            if entry_count > MAX_SUBTREE_ENTRIES {
                return Err(format!(
                    "native owner subtree exceeds {MAX_SUBTREE_ENTRIES} entries"
                ));
            }
            let path = entry.path();
            let metadata = fs::symlink_metadata(&path).map_err(|error| {
                format!("cannot inspect source entry '{}': {error}", path.display())
            })?;
            if is_reparse(&metadata) {
                return Err(format!(
                    "native owner subtree cannot contain a reparse point: {}",
                    path.display()
                ));
            }
            if metadata.is_dir() {
                let name = unicode_name(&path)?;
                if !valid_command_segment(&name) {
                    continue;
                }
                let Some(manifest_path) = canonical_manifest_path(&path)? else {
                    continue;
                };
                manifest_count += 1;
                if manifest_count > MAX_MANIFESTS {
                    return Err(format!(
                        "native owner subtree exceeds {MAX_MANIFESTS} manifests"
                    ));
                }
                let relative = path.strip_prefix(command_root).map_err(|_| {
                    format!("command directory escaped command root: {}", path.display())
                })?;
                let identity = relative_identity(owner, relative)?;
                let address = identity.address();
                let manifest = read_manifest_directory(&path, &manifest_path)?;
                match &manifest.execution {
                    Some(CommandModuleExecution::Native) => nested_owner_directories.push(path),
                    Some(CommandModuleExecution::Delegate { owner: declared }) => {
                        if command_reference_identity(declared)? == *owner {
                            commands.push(contract_command(
                                address,
                                ExecutionSemantics::Delegate {
                                    owner: owner.address(),
                                },
                                manifest,
                            ));
                        }
                        pending.push(path);
                    }
                    _ => pending.push(path),
                }
            }
        }
    }
    Ok(())
}

fn contract_command(
    address: String,
    execution: ExecutionSemantics,
    manifest: CommandModuleManifest,
) -> ExecutionContractCommand {
    ExecutionContractCommand {
        address,
        execution,
        requires: manifest.requires,
        provides: manifest.provides,
    }
}

fn read_manifest(path: &Path) -> Result<CommandModuleManifest, String> {
    let bytes = read_regular_file(path, "command manifest", MAX_MANIFEST_BYTES)?;
    parse_command_module(&bytes)
        .map_err(|error| format!("invalid command manifest '{}': {error}", path.display()))
}

fn read_manifest_in(directory: &Path) -> Result<CommandModuleManifest, String> {
    let path = canonical_manifest_path(directory)?.ok_or_else(|| {
        format!(
            "command manifest '{MODULE_MANIFEST}' is missing below '{}'",
            directory.display()
        )
    })?;
    read_manifest_directory(directory, &path)
}

fn read_manifest_directory(directory: &Path, path: &Path) -> Result<CommandModuleManifest, String> {
    let manifest = read_manifest(path)?;
    let local_entry = local_entry::resolve(directory)?;
    if local_entry.is_some() && manifest.execution.is_some() {
        return Err(format!(
            "command '{}' declares both a local run.* entry and {MODULE_MANIFEST} execution",
            directory.display()
        ));
    }
    Ok(manifest)
}

fn canonical_directory<'a>(
    root: &Path,
    segments: impl IntoIterator<Item = &'a String>,
    root_label: &str,
    label: &str,
) -> Result<PathBuf, String> {
    regular_directory(root, root_label)?;
    let mut current = root.to_path_buf();
    for expected in segments {
        let mut matches = Vec::new();
        for entry in fs::read_dir(&current)
            .map_err(|error| format!("cannot enumerate '{}': {error}", current.display()))?
        {
            let entry = entry
                .map_err(|error| format!("cannot enumerate '{}': {error}", current.display()))?;
            let name = entry
                .file_name()
                .into_string()
                .map_err(|_| format!("{label} contains a non-Unicode name"))?;
            if name.eq_ignore_ascii_case(expected) {
                matches.push((name, entry.path()));
            }
        }
        if matches.len() != 1 {
            return Err(format!(
                "{label} has missing or colliding segment '{expected}' below '{}'",
                current.display()
            ));
        }
        let (actual, path) = matches.pop().expect("one canonical match");
        if actual != *expected {
            return Err(format!(
                "non-canonical command directory '{actual}'; expected '{expected}'"
            ));
        }
        regular_directory(&path, label)?;
        current = path;
    }
    Ok(current)
}

fn canonical_manifest_path(directory: &Path) -> Result<Option<PathBuf>, String> {
    let mut matches = Vec::new();
    for entry in fs::read_dir(directory)
        .map_err(|error| format!("cannot enumerate '{}': {error}", directory.display()))?
    {
        let entry = entry
            .map_err(|error| format!("cannot enumerate '{}': {error}", directory.display()))?;
        let name = entry
            .file_name()
            .into_string()
            .map_err(|_| "command directory contains a non-Unicode name".to_owned())?;
        if name.eq_ignore_ascii_case(MODULE_MANIFEST) {
            matches.push((name, entry.path()));
        }
    }
    if matches.len() > 1 {
        return Err(format!(
            "command manifest file name collision below '{}': {}",
            directory.display(),
            matches
                .iter()
                .map(|(name, _)| name.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }
    let Some((name, path)) = matches.pop() else {
        return Ok(None);
    };
    if name != MODULE_MANIFEST {
        return Err(format!(
            "non-canonical command manifest '{name}'; expected '{MODULE_MANIFEST}'"
        ));
    }
    let metadata = fs::symlink_metadata(&path).map_err(|error| {
        format!(
            "cannot inspect command manifest '{}': {error}",
            path.display()
        )
    })?;
    if !metadata.is_file() || is_reparse(&metadata) {
        return Err(format!(
            "command manifest must be a regular file: {}",
            path.display()
        ));
    }
    Ok(Some(path))
}

fn command_source_root<'a>(
    system_root: &'a Path,
    module_roots: &'a BTreeMap<String, PathBuf>,
    identity: &CommandIdentity,
) -> Result<&'a Path, String> {
    match identity.space() {
        CommandSpace::System => Ok(system_root),
        CommandSpace::Module => {
            let namespace = identity
                .namespace()
                .expect("Module command identity must have a namespace");
            module_roots
                .get(namespace)
                .map(PathBuf::as_path)
                .ok_or_else(|| format!("Module namespace '{namespace}' is not mounted"))
        }
    }
}

fn command_reference_identity(
    reference: &CommandModuleSubjectRef,
) -> Result<CommandIdentity, String> {
    let CommandModuleSubjectRef::Command {
        space,
        namespace,
        address,
    } = reference
    else {
        return Err("validated delegate owner is not a command reference".to_owned());
    };
    let identity = CommandIdentity::parse(address).map_err(|error| error.to_string())?;
    if identity.space() != *space || identity.namespace() != namespace.as_deref() {
        return Err("delegate owner identity fields are inconsistent".to_owned());
    }
    Ok(identity)
}

fn relative_identity(owner: &CommandIdentity, path: &Path) -> Result<CommandIdentity, String> {
    let segments = path
        .components()
        .map(|component| {
            component
                .as_os_str()
                .to_str()
                .map(str::to_owned)
                .ok_or_else(|| format!("command path is not Unicode: {}", path.display()))
        })
        .collect::<Result<Vec<_>, _>>()?;
    CommandIdentity::new(owner.space(), owner.namespace(), segments)
        .map_err(|error| error.to_string())
}

fn unicode_name(path: &Path) -> Result<String, String> {
    path.file_name()
        .and_then(|name| name.to_str())
        .map(str::to_owned)
        .ok_or_else(|| format!("source path is not Unicode: {}", path.display()))
}

#[cfg(test)]
#[path = "manifest/tests.rs"]
mod tests;
