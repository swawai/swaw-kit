use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use swawkit_proj_protocol::{
    CommandModuleCommandSpace, CommandModuleExecution, CommandModuleManifest,
    CommandModuleSubjectRef, ExecutionContract, ExecutionContractCommand, ExecutionSemantics,
    parse_command_module, valid_command_segment, validate_command_address,
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
    module_roots: &BTreeMap<String, PathBuf>,
    requested: &str,
) -> Result<NativeDomain, String> {
    let requested_address = Address::parse(requested)?;
    let root = module_roots
        .get(&requested_address.namespace)
        .ok_or_else(|| {
            format!(
                "Module namespace '{}' is not mounted",
                requested_address.namespace
            )
        })?;
    regular_directory(root, "Module mount root")?;
    let requested_directory = canonical_directory(
        root,
        requested_address.segments.iter().skip(1),
        "command source directory",
    )?;
    let requested_manifest = read_manifest_in(&requested_directory)?;
    let owner_address = match requested_manifest.execution {
        Some(CommandModuleExecution::Native) => requested.to_owned(),
        Some(CommandModuleExecution::Delegate { owner }) => {
            let owner = module_command_address(&owner)?;
            if owner == requested || !is_true_ancestor(owner, requested) {
                return Err(format!(
                    "delegate '{requested}' must name a true ancestor owner"
                ));
            }
            owner.to_owned()
        }
        _ => {
            return Err(format!(
                "command '{requested}' is not a native owner or delegated port"
            ));
        }
    };
    let owner = Address::parse(&owner_address)?;
    if owner.namespace != requested_address.namespace {
        return Err("native owner and delegated command must share one namespace".to_owned());
    }
    let owner_directory = canonical_directory(
        root,
        owner.segments.iter().skip(1),
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
        root,
        &owner,
        &owner_directory,
        &mut commands,
        &mut nested_owner_directories,
    )?;
    let execution_contract = ExecutionContract::new(owner_address.clone(), commands)
        .map_err(|error| format!("invalid native execution contract: {error}"))?;
    Ok(NativeDomain {
        requested_address: requested.to_owned(),
        owner_address,
        owner_directory,
        nested_owner_directories,
        execution_contract,
    })
}

fn collect_delegates(
    module_root: &Path,
    owner: &Address,
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
                let relative = path.strip_prefix(module_root).map_err(|_| {
                    format!("command directory escaped Module root: {}", path.display())
                })?;
                let address = relative_address(&owner.namespace, relative)?;
                let manifest = read_manifest_directory(&path, &manifest_path)?;
                match &manifest.execution {
                    Some(CommandModuleExecution::Native) => nested_owner_directories.push(path),
                    Some(CommandModuleExecution::Delegate { owner: declared }) => {
                        if module_command_address(declared)? == owner.text {
                            commands.push(contract_command(
                                address,
                                ExecutionSemantics::Delegate {
                                    owner: owner.text.clone(),
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
    let bytes = read_regular_file(path, "Module manifest", MAX_MANIFEST_BYTES)?;
    parse_command_module(&bytes)
        .map_err(|error| format!("invalid Module manifest '{}': {error}", path.display()))
}

fn read_manifest_in(directory: &Path) -> Result<CommandModuleManifest, String> {
    let path = canonical_manifest_path(directory)?.ok_or_else(|| {
        format!(
            "Module manifest '{MODULE_MANIFEST}' is missing below '{}'",
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
    label: &str,
) -> Result<PathBuf, String> {
    regular_directory(root, "Module mount root")?;
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
            .map_err(|_| "Module directory contains a non-Unicode name".to_owned())?;
        if name.eq_ignore_ascii_case(MODULE_MANIFEST) {
            matches.push((name, entry.path()));
        }
    }
    if matches.len() > 1 {
        return Err(format!(
            "Module manifest file name collision below '{}': {}",
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
            "non-canonical Module manifest '{name}'; expected '{MODULE_MANIFEST}'"
        ));
    }
    let metadata = fs::symlink_metadata(&path).map_err(|error| {
        format!(
            "cannot inspect Module manifest '{}': {error}",
            path.display()
        )
    })?;
    if !metadata.is_file() || is_reparse(&metadata) {
        return Err(format!(
            "Module manifest must be a regular file: {}",
            path.display()
        ));
    }
    Ok(Some(path))
}

fn module_command_address(reference: &CommandModuleSubjectRef) -> Result<&str, String> {
    match reference {
        CommandModuleSubjectRef::Command {
            space: CommandModuleCommandSpace::Module,
            namespace: Some(_),
            address,
        } => Ok(address),
        _ => Err("validated delegate owner is not a Module command reference".to_owned()),
    }
}

struct Address {
    text: String,
    namespace: String,
    segments: Vec<String>,
}

impl Address {
    fn parse(value: &str) -> Result<Self, String> {
        validate_command_address(value).map_err(|error| error.to_string())?;
        let segments = value.split('/').map(str::to_owned).collect::<Vec<_>>();
        Ok(Self {
            text: value.to_owned(),
            namespace: segments[0].clone(),
            segments,
        })
    }
}

fn relative_address(namespace: &str, path: &Path) -> Result<String, String> {
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
    let address = format!("{namespace}/{}", segments.join("/"));
    validate_command_address(&address).map_err(|error| error.to_string())?;
    Ok(address)
}

fn is_true_ancestor(owner: &str, command: &str) -> bool {
    command
        .strip_prefix(owner)
        .is_some_and(|tail| tail.starts_with('/') && tail.len() > 1)
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
