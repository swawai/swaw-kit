use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use swawkit_proj_protocol::{
    CommandIdentity, CommandProvision, CommandRequirement, CommandSpace, ExecutionContract,
    ExecutionContractCommand, ExecutionSemantics, FacetExecution, FacetRoute, ResourceFacetKind,
    ResourceRoute, parse_facet_execution_manifest, parse_facet_requirements_manifest,
    parse_resource_exports_manifest, parse_resource_facet_manifest, parse_resource_manifest,
    valid_command_segment,
};

use crate::filesystem::{is_reparse, read_regular_file, regular_directory};

mod local_entry;

const RESOURCE_FILE: &str = "swawkit.resource.json";
const FACET_FILE: &str = "swawkit.facet.json";
const EXECUTION_FILE: &str = "swawkit.execution.json";
const REQUIREMENTS_FILE: &str = "swawkit.requirements.json";
const EXPORTS_FILE: &str = "swawkit.exports.json";
const EXECUTE_FACET: &str = "execute";
const SUBCOMMANDS_FACET: &str = "subcommands";
const MAX_DOCUMENT_BYTES: u64 = 1024 * 1024;
const MAX_RESOURCES: usize = 4096;
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

struct CommandDeclaration {
    execution: FacetExecution,
    requirements: Vec<CommandRequirement>,
    provisions: Vec<CommandProvision>,
}

pub(crate) fn discover_native_domain(
    system_root: &Path,
    module_roots: &BTreeMap<String, PathBuf>,
    requested: &str,
) -> Result<NativeDomain, String> {
    let requested_identity =
        CommandIdentity::parse(requested).map_err(|error| error.to_string())?;
    let root = command_source_root(system_root, module_roots, &requested_identity)?;
    let requested_directory = canonical_resource_directory(root, &requested_identity)?;
    let requested_declaration = read_command_declaration(&requested_directory)?;
    let owner_identity = match &requested_declaration.execution {
        FacetExecution::Native => requested_identity.clone(),
        FacetExecution::NativeDelegate { owner } => {
            let owner = command_identity_for_execute_facet(owner)?;
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
    let owner_directory = canonical_resource_directory(owner_root, &owner_identity)?;
    let owner_declaration = read_command_declaration(&owner_directory)?;
    if !matches!(owner_declaration.execution, FacetExecution::Native) {
        return Err(format!(
            "declared native owner '{owner_address}' does not use native execute semantics"
        ));
    }

    let mut commands = vec![contract_command(
        owner_address.clone(),
        ExecutionSemantics::Native,
        owner_declaration,
    )];
    let mut nested_owner_directories = Vec::new();
    collect_delegates(
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
    owner: &CommandIdentity,
    owner_directory: &Path,
    commands: &mut Vec<ExecutionContractCommand>,
    nested_owner_directories: &mut Vec<PathBuf>,
) -> Result<(), String> {
    let mut pending = vec![(owner_directory.to_path_buf(), owner.clone())];
    let mut resource_count = 0_usize;
    let mut entry_count = 0_usize;
    while let Some((directory, identity)) = pending.pop() {
        let Some(children) = subcommand_directories(&directory, &mut entry_count)? else {
            continue;
        };
        for (selector, child_directory) in children {
            resource_count += 1;
            if resource_count > MAX_RESOURCES {
                return Err(format!(
                    "native owner subtree exceeds {MAX_RESOURCES} Resources"
                ));
            }
            let mut path = identity.path().to_vec();
            path.push(selector);
            let child_identity = CommandIdentity::new(identity.space(), identity.namespace(), path)
                .map_err(|error| error.to_string())?;
            let declaration = read_command_declaration(&child_directory)?;
            match &declaration.execution {
                FacetExecution::Native => nested_owner_directories.push(child_directory),
                FacetExecution::NativeDelegate { owner: declared } => {
                    if command_identity_for_execute_facet(declared)? == *owner {
                        commands.push(contract_command(
                            child_identity.address(),
                            ExecutionSemantics::Delegate {
                                owner: owner.address(),
                            },
                            declaration,
                        ));
                    }
                    pending.push((child_directory, child_identity));
                }
                _ => pending.push((child_directory, child_identity)),
            }
        }
    }
    Ok(())
}

fn contract_command(
    address: String,
    execution: ExecutionSemantics,
    declaration: CommandDeclaration,
) -> ExecutionContractCommand {
    ExecutionContractCommand {
        address,
        execution,
        requires: declaration.requirements,
        provides: declaration.provisions,
    }
}

fn read_command_declaration(directory: &Path) -> Result<CommandDeclaration, String> {
    let resource = read_protocol(directory, RESOURCE_FILE, true)?.expect("required protocol file");
    let resource = parse_resource_manifest(&resource)
        .map_err(|error| format!("invalid Resource '{}': {error}", directory.display()))?;
    if resource.kind != "command" {
        return Err(format!(
            "native command Resource '{}' must use kind 'command'",
            directory.display()
        ));
    }

    let execute =
        canonical_child_directory(directory, EXECUTE_FACET, true)?.expect("required execute Facet");
    let facet = read_protocol(&execute, FACET_FILE, true)?.expect("required Facet protocol");
    let facet = parse_resource_facet_manifest(&facet)
        .map_err(|error| format!("invalid execute Facet '{}': {error}", execute.display()))?;
    if facet.kind != ResourceFacetKind::Operation {
        return Err("execute Facet must be an operation".to_owned());
    }
    let execution =
        read_protocol(&execute, EXECUTION_FILE, true)?.expect("required execution protocol");
    let execution = parse_facet_execution_manifest(&execution)
        .map_err(|error| {
            format!(
                "invalid execute declaration '{}': {error}",
                execute.display()
            )
        })?
        .implementation;
    if local_entry::resolve(&execute)?.is_some() {
        return Err(format!(
            "execute Facet '{}' declares both a local run.* entry and {EXECUTION_FILE}",
            execute.display()
        ));
    }

    let requirements = read_protocol(&execute, REQUIREMENTS_FILE, false)?
        .map(|bytes| {
            parse_facet_requirements_manifest(&bytes)
                .map_err(|error| format!("invalid requirements '{}': {error}", execute.display()))
        })
        .transpose()?
        .map(|manifest| {
            manifest
                .requirements
                .into_iter()
                .map(|requirement| {
                    Ok(CommandRequirement {
                        provider: command_identity_for_resource(
                            &ResourceRoute::parse(&requirement.provider)
                                .map_err(|error| error.to_string())?,
                        )?
                        .address(),
                        export: requirement.export,
                    })
                })
                .collect::<Result<Vec<_>, String>>()
        })
        .transpose()?
        .unwrap_or_default();
    let provisions = read_protocol(directory, EXPORTS_FILE, false)?
        .map(|bytes| {
            parse_resource_exports_manifest(&bytes)
                .map_err(|error| format!("invalid exports '{}': {error}", directory.display()))
        })
        .transpose()?
        .map(|manifest| {
            manifest
                .exports
                .into_iter()
                .map(|export| CommandProvision { id: export.id })
                .collect()
        })
        .unwrap_or_default();
    Ok(CommandDeclaration {
        execution,
        requirements,
        provisions,
    })
}

fn subcommand_directories(
    resource: &Path,
    entry_count: &mut usize,
) -> Result<Option<Vec<(String, PathBuf)>>, String> {
    let Some(collection) = canonical_child_directory(resource, SUBCOMMANDS_FACET, false)? else {
        return Ok(None);
    };
    let facet = read_protocol(&collection, FACET_FILE, true)?.expect("required Facet protocol");
    let facet = parse_resource_facet_manifest(&facet).map_err(|error| {
        format!(
            "invalid subcommands Facet '{}': {error}",
            collection.display()
        )
    })?;
    if facet.kind != ResourceFacetKind::Collection {
        return Err("subcommands Facet must be a collection".to_owned());
    }
    let mut children = Vec::new();
    for entry in fs::read_dir(&collection)
        .map_err(|error| format!("cannot enumerate '{}': {error}", collection.display()))?
    {
        let entry = entry
            .map_err(|error| format!("cannot enumerate '{}': {error}", collection.display()))?;
        *entry_count += 1;
        if *entry_count > MAX_SUBTREE_ENTRIES {
            return Err(format!(
                "native owner subtree exceeds {MAX_SUBTREE_ENTRIES} entries"
            ));
        }
        let path = entry.path();
        let metadata = fs::symlink_metadata(&path)
            .map_err(|error| format!("cannot inspect '{}': {error}", path.display()))?;
        if !metadata.is_dir() || is_reparse(&metadata) {
            continue;
        }
        let selector = unicode_name(&path)?;
        if !valid_command_segment(&selector) {
            continue;
        }
        if read_protocol(&path, RESOURCE_FILE, false)?.is_some() {
            children.push((selector, path));
        }
    }
    children.sort_by(|left, right| left.0.cmp(&right.0));
    Ok(Some(children))
}

fn canonical_resource_directory(
    root: &Path,
    identity: &CommandIdentity,
) -> Result<PathBuf, String> {
    regular_directory(root, "command source root")?;
    let mut segments = identity.path().iter();
    let first = segments
        .next()
        .ok_or_else(|| "a native command identity cannot name a namespace root".to_owned())?;
    let mut current = canonical_child_directory(root, first, true)?.expect("required directory");
    for segment in segments {
        let collection = canonical_child_directory(&current, SUBCOMMANDS_FACET, true)?
            .expect("required subcommands Facet");
        current = canonical_child_directory(&collection, segment, true)?
            .expect("required command Resource");
    }
    Ok(current)
}

fn command_identity_for_execute_facet(route: &str) -> Result<CommandIdentity, String> {
    let facet = FacetRoute::parse(route).map_err(|error| error.to_string())?;
    if facet.facet() != EXECUTE_FACET {
        return Err("delegate owner must name an execute Facet".to_owned());
    }
    command_identity_for_resource(facet.resource())
}

fn command_identity_for_resource(route: &ResourceRoute) -> Result<CommandIdentity, String> {
    let Some(root) = route.hops().first() else {
        return Err("root Resource is not backed by a command".to_owned());
    };
    let (space, namespace, mut path) = match root.facet() {
        "system" => (CommandSpace::System, None, vec![root.selector().to_owned()]),
        "modules" => (CommandSpace::Module, Some(root.selector()), Vec::new()),
        _ => return Err("command Resource must begin at system or modules".to_owned()),
    };
    for hop in &route.hops()[1..] {
        if hop.facet() != SUBCOMMANDS_FACET {
            return Err("command Resource may traverse only subcommands".to_owned());
        }
        path.push(hop.selector().to_owned());
    }
    CommandIdentity::new(space, namespace, path).map_err(|error| error.to_string())
}

fn read_protocol(
    directory: &Path,
    expected: &str,
    required: bool,
) -> Result<Option<Vec<u8>>, String> {
    let mut matches = Vec::new();
    for entry in fs::read_dir(directory)
        .map_err(|error| format!("cannot enumerate '{}': {error}", directory.display()))?
    {
        let entry = entry
            .map_err(|error| format!("cannot enumerate '{}': {error}", directory.display()))?;
        let name = entry.file_name().into_string().map_err(|_| {
            format!(
                "source directory '{}' contains a non-Unicode name",
                directory.display()
            )
        })?;
        if name.eq_ignore_ascii_case(expected) {
            matches.push((name, entry.path()));
        }
    }
    if matches.len() > 1 {
        return Err(format!(
            "protocol file name collision below '{}': {}",
            directory.display(),
            matches
                .iter()
                .map(|item| item.0.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }
    let Some((name, path)) = matches.pop() else {
        return if required {
            Err(format!(
                "required protocol '{expected}' is missing below '{}'",
                directory.display()
            ))
        } else {
            Ok(None)
        };
    };
    if name != expected {
        return Err(format!(
            "non-canonical protocol file '{name}'; expected '{expected}'"
        ));
    }
    read_regular_file(&path, expected, MAX_DOCUMENT_BYTES).map(Some)
}

fn canonical_child_directory(
    parent: &Path,
    expected: &str,
    required: bool,
) -> Result<Option<PathBuf>, String> {
    let mut matches = Vec::new();
    for entry in fs::read_dir(parent)
        .map_err(|error| format!("cannot enumerate '{}': {error}", parent.display()))?
    {
        let entry =
            entry.map_err(|error| format!("cannot enumerate '{}': {error}", parent.display()))?;
        let name = entry.file_name().into_string().map_err(|_| {
            format!(
                "source directory '{}' contains a non-Unicode name",
                parent.display()
            )
        })?;
        if name.eq_ignore_ascii_case(expected) {
            matches.push((name, entry.path()));
        }
    }
    if matches.len() > 1 {
        return Err(format!(
            "directory name collision for '{expected}' below '{}'",
            parent.display()
        ));
    }
    let Some((name, path)) = matches.pop() else {
        return if required {
            Err(format!(
                "required directory '{expected}' is missing below '{}'",
                parent.display()
            ))
        } else {
            Ok(None)
        };
    };
    if name != expected {
        return Err(format!(
            "non-canonical directory '{name}'; expected '{expected}'"
        ));
    }
    regular_directory(&path, expected)?;
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

fn unicode_name(path: &Path) -> Result<String, String> {
    path.file_name()
        .and_then(|name| name.to_str())
        .map(str::to_owned)
        .ok_or_else(|| format!("source path is not Unicode: {}", path.display()))
}

#[cfg(test)]
#[path = "manifest/tests.rs"]
mod tests;
