use crate::{
    context::EntryContext,
    entry_config::{EntryConfig, EntryLanguage},
    subject::SubjectRef,
};
use serde::Serialize;
use std::collections::VecDeque;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use swawkit_proj_protocol::CommandIdentity;

mod address;
mod entry;
mod facet;
mod filesystem;
mod identity;
mod module_contract;
mod subject_kind;
mod view;

pub use crate::facet::{Facet, FacetKind, FacetRenderer, FacetResolver};
use address::child_address;
pub(crate) use entry::{CommandAdapter, ResolvedEntry, resolve_entry};
use facet::resolve_command_facets;
pub(crate) use filesystem::named_directories;
use filesystem::{
    FileCandidate, absolute_path, assert_command_root, child_directories, directory_files,
};
use identity::CommandId;
pub use identity::CommandSpace;
pub(crate) use module_contract::MODULE_CONTRACT_FILE;
use module_contract::read_local_module_contract;
pub use module_contract::{
    CommandModuleContract, MODULE_CONTRACT_PROTOCOL, ModuleExecution, ModuleProvision,
    ModuleRequirement,
};
use subject_kind::resolve_subject_kinds;
use view::read_local_web_view;
pub use view::{ChildrenColumnView, ColumnWidth, CommandView, RunOperationView, RunView};

pub const CATALOG_PROTOCOL: &str = "swawkit.command-catalog/v19";

pub const HELP_ADDRESS: &str = ".help";
pub const HELP_MARKERS: [&str; 3] = [HELP_ADDRESS, "-h", "--help"];

pub fn is_help_marker(value: &str) -> bool {
    HELP_MARKERS.contains(&value)
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogSnapshot {
    pub protocol: &'static str,
    pub entry_name: String,
    pub language: &'static str,
    pub commands: Vec<CommandNode>,
}

impl CatalogSnapshot {
    pub fn discover(context: &EntryContext, config: Option<&EntryConfig>) -> io::Result<Self> {
        let mut module_roots = vec![ModuleRoot::new("swaw", context.swaw_module_root())];
        if let Some(binding) = config.and_then(EntryConfig::binding) {
            module_roots.push(ModuleRoot::new("project", binding.project_module_root()));
        }
        let language = config.map(EntryConfig::language).unwrap_or_default();
        Self::discover_optional_roots(
            &context.system_root(),
            &module_roots,
            &context.entry_name,
            language,
        )
    }

    pub fn discover_roots(
        system_root: &Path,
        swaw_module_root: &Path,
        project_module_root: &Path,
        entry_name: &str,
    ) -> io::Result<Self> {
        let module_roots = [
            ModuleRoot::new("swaw", swaw_module_root.to_owned()),
            ModuleRoot::new("project", project_module_root.to_owned()),
        ];
        Self::discover_optional_roots(
            system_root,
            &module_roots,
            entry_name,
            EntryLanguage::default(),
        )
    }

    #[cfg(test)]
    fn discover_roots_in_language(
        system_root: &Path,
        swaw_module_root: &Path,
        project_module_root: &Path,
        entry_name: &str,
        language: EntryLanguage,
    ) -> io::Result<Self> {
        let module_roots = [
            ModuleRoot::new("swaw", swaw_module_root.to_owned()),
            ModuleRoot::new("project", project_module_root.to_owned()),
        ];
        Self::discover_optional_roots(system_root, &module_roots, entry_name, language)
    }

    fn discover_optional_roots(
        system_root: &Path,
        module_roots: &[ModuleRoot],
        entry_name: &str,
        language: EntryLanguage,
    ) -> io::Result<Self> {
        assert_command_root(system_root)?;

        let system_path = absolute_path(system_root)?;
        let mut commands = scan_root(
            PendingDirectory {
                module: read_pending_module(&system_path, language),
                path: system_path,
                id: CommandId::system(Vec::new()),
            },
            entry_name,
            language,
        )?;

        for module_root in module_roots {
            let scanned = (|| {
                let Some(path) = safe_optional_module_root(&module_root.path)? else {
                    return Ok(Vec::new());
                };
                scan_root(
                    PendingDirectory {
                        module: read_pending_module(&path, language),
                        path,
                        id: CommandId::module(&module_root.namespace, Vec::new()),
                    },
                    entry_name,
                    language,
                )
            })();
            match scanned {
                Ok(mut scanned) => commands.append(&mut scanned),
                Err(_) if module_root.namespace == "project" => {}
                Err(error) => return Err(error),
            }
        }

        commands.sort_by(|left, right| {
            left.space
                .cmp(&right.space)
                .then_with(|| left.address.cmp(&right.address))
        });
        resolve_native_owners(&mut commands);
        resolve_subject_kinds(&mut commands);
        resolve_command_facets(&mut commands, language);

        Ok(Self {
            protocol: CATALOG_PROTOCOL,
            entry_name: entry_name.to_owned(),
            language: language.as_str(),
            commands,
        })
    }
}

pub(crate) fn safe_optional_module_root(path: &Path) -> io::Result<Option<PathBuf>> {
    match fs::symlink_metadata(path) {
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    }
    assert_command_root(path)?;
    absolute_path(path).map(Some)
}

fn scan_root(
    root: PendingDirectory,
    entry_name: &str,
    language: EntryLanguage,
) -> io::Result<Vec<CommandNode>> {
    let mut pending = VecDeque::from([root]);
    let mut commands = Vec::new();
    while let Some(current) = pending.pop_front() {
        commands.push(scan_node(&current, entry_name, language));
        for child in child_directories(&current.path)? {
            let Some(child_command) = child_address(&current, &child.name) else {
                continue;
            };
            let module = read_pending_module(&child.path, language);
            if !matches!(module, PendingModule::Absent) {
                pending.push_back(PendingDirectory {
                    path: child.path,
                    id: child_command.id,
                    module,
                });
            }
        }
    }
    Ok(commands)
}

#[derive(Debug, Clone)]
struct ModuleRoot {
    namespace: String,
    path: PathBuf,
}

impl ModuleRoot {
    fn new(namespace: impl Into<String>, path: PathBuf) -> Self {
        Self {
            namespace: namespace.into(),
            path,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandNode {
    pub address: String,
    pub space: CommandSpace,
    pub namespace: Option<String>,
    pub path: Vec<String>,
    pub parent: Option<String>,
    pub alias_of: Option<String>,
    pub runnable: bool,
    pub entry: Option<String>,
    pub adapter: Option<String>,
    pub handler: Option<String>,
    pub product: Option<String>,
    pub module: Option<CommandModuleContract>,
    pub help: Option<HelpDocument>,
    pub subject_kinds: Vec<crate::subject_kind::SubjectKind>,
    pub facets: Vec<Facet>,
    pub view: Option<CommandView>,
    pub diagnostic: Option<String>,
    /// Retains the Help protocol state without expanding the public Web API.
    #[serde(skip)]
    pub help_diagnostic: Option<String>,
    #[serde(skip)]
    pub directory: PathBuf,
    #[serde(skip)]
    pub(crate) native_owner: Option<String>,
}

impl CommandNode {
    pub fn is_control(&self) -> bool {
        self.space == CommandSpace::System
            && self
                .path
                .first()
                .is_some_and(|segment| matches!(segment.as_str(), "entry" | "runtime"))
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct HelpDocument {
    pub summary: String,
    pub text: String,
}

#[derive(Debug)]
struct PendingDirectory {
    path: PathBuf,
    id: CommandId,
    module: PendingModule,
}

#[derive(Debug)]
enum PendingModule {
    Absent,
    Valid(CommandModuleContract),
    Invalid(String),
}

fn read_pending_module(path: &Path, language: EntryLanguage) -> PendingModule {
    match read_local_module_contract(path, language) {
        Ok(Some(module)) => PendingModule::Valid(module),
        Ok(None) => PendingModule::Absent,
        Err(error) => PendingModule::Invalid(error.to_string()),
    }
}

#[derive(Debug)]
struct ChildCommand {
    id: CommandId,
}

fn scan_node(pending: &PendingDirectory, entry_name: &str, language: EntryLanguage) -> CommandNode {
    let address = pending.id.address();
    let mut diagnostics = Vec::new();
    let (module, module_valid) = match &pending.module {
        PendingModule::Absent => (None, true),
        PendingModule::Valid(module) => (Some(module.clone()), true),
        PendingModule::Invalid(error) => {
            diagnostics.push(error.clone());
            (None, false)
        }
    };
    let local_entry = match resolve_entry(&pending.path) {
        Ok(entry) => entry,
        Err(error) => {
            diagnostics.push(error.to_string());
            None
        }
    };
    let declared_execution = module
        .as_ref()
        .and_then(|contract| contract.execution.as_ref());
    let entry = match (local_entry, declared_execution) {
        (Some(_), Some(_)) => {
            diagnostics.push(format!(
                "command declares both a local run.* entry and {MODULE_CONTRACT_FILE} execution"
            ));
            None
        }
        (None, Some(ModuleExecution::Core { handler })) => Some(ResolvedEntry::declared(
            CommandAdapter::Core,
            Some(handler.clone()),
            None,
        )),
        (None, Some(ModuleExecution::Runtime { product })) => Some(ResolvedEntry::declared(
            CommandAdapter::Runtime,
            None,
            Some(product.clone()),
        )),
        (None, Some(ModuleExecution::Native)) => {
            Some(ResolvedEntry::declared(CommandAdapter::Native, None, None))
        }
        (None, Some(ModuleExecution::Delegate { .. })) => Some(ResolvedEntry::declared(
            CommandAdapter::Delegate,
            None,
            None,
        )),
        (entry, None) => entry,
    };
    let entry = entry.and_then(|entry| {
        if let Some(diagnostic) = entry.invalid_declared_owner(pending.id.space, &address) {
            diagnostics.push(diagnostic.to_owned());
            None
        } else {
            Some(entry)
        }
    });
    let entry = match entry {
        Some(entry)
            if entry.adapter == CommandAdapter::Bun && pending.id.space != CommandSpace::Module =>
        {
            diagnostics.push("run.ts is restricted to Module commands".to_owned());
            None
        }
        Some(entry) if entry.adapter == CommandAdapter::Python => {
            diagnostics.push(
                "run.py is not runnable until Python is part of the Framework Command Runtime"
                    .to_owned(),
            );
            None
        }
        entry if module_valid => entry,
        _ => None,
    };
    let (help, help_diagnostic) =
        match read_local_help(&pending.path, entry_name, &address, language) {
            Ok(help) => (help, None),
            Err(error) => {
                let diagnostic = error.to_string();
                diagnostics.push(diagnostic.clone());
                (None, Some(diagnostic))
            }
        };
    let view = match read_local_web_view(&pending.path) {
        Ok(view) => view,
        Err(error) => {
            diagnostics.push(error.to_string());
            None
        }
    };

    CommandNode {
        address,
        space: pending.id.space,
        namespace: pending.id.namespace.clone(),
        path: pending.id.path.clone(),
        parent: pending.id.parent().map(|parent| parent.address()),
        alias_of: None,
        runnable: entry.is_some(),
        entry: entry.as_ref().map(|entry| entry.name.to_owned()),
        adapter: entry
            .as_ref()
            .map(|entry| entry.adapter.as_str().to_owned()),
        handler: entry.as_ref().and_then(|entry| entry.handler.clone()),
        product: entry.and_then(|entry| entry.product),
        module,
        help,
        subject_kinds: Vec::new(),
        facets: Vec::new(),
        view,
        diagnostic: (!diagnostics.is_empty()).then(|| diagnostics.join("; ")),
        help_diagnostic,
        directory: pending.path.clone(),
        native_owner: None,
    }
}

fn resolve_native_owners(commands: &mut [CommandNode]) {
    let entries = commands
        .iter()
        .map(|command| {
            (
                command.address.clone(),
                (
                    command.space,
                    command.namespace.clone(),
                    command.path.clone(),
                    command.adapter.clone(),
                    command
                        .module
                        .as_ref()
                        .and_then(|module| module.execution.as_ref())
                        .is_some_and(|execution| matches!(execution, ModuleExecution::Native)),
                ),
            )
        })
        .collect::<std::collections::BTreeMap<_, _>>();

    for command in commands {
        match command.adapter.as_deref() {
            Some("native") if command.runnable => {
                command.native_owner = Some(command.address.clone());
            }
            Some("delegate") if command.runnable => {
                match delegated_native_owner(&entries, command) {
                    Ok(owner) => command.native_owner = Some(owner),
                    Err(diagnostic) => {
                        command.runnable = false;
                        command.entry = None;
                        command.adapter = None;
                        command.handler = None;
                        command.product = None;
                        command.diagnostic = Some(match command.diagnostic.take() {
                            Some(existing) => format!("{existing}; {diagnostic}"),
                            None => diagnostic,
                        });
                    }
                }
            }
            _ => {}
        }
    }
}

fn delegated_native_owner(
    entries: &std::collections::BTreeMap<
        String,
        (
            CommandSpace,
            Option<String>,
            Vec<String>,
            Option<String>,
            bool,
        ),
    >,
    command: &CommandNode,
) -> Result<String, String> {
    let Some(ModuleExecution::Delegate { owner }) = command
        .module
        .as_ref()
        .and_then(|module| module.execution.as_ref())
    else {
        return Err(format!(
            "delegated command '{}' has no execution owner declaration",
            command.address
        ));
    };
    let SubjectRef::Command {
        space,
        namespace,
        address,
    } = owner
    else {
        return Err("delegated execution owner must be a command".to_owned());
    };
    if *space != command.space || namespace != &command.namespace {
        return Err(format!(
            "delegated execution owner '{}' must use the command's space and namespace",
            address
        ));
    }
    let Some((owner_space, owner_namespace, owner_path, adapter, _)) = entries.get(address) else {
        return Err(format!(
            "delegated execution owner '{}' is missing from the Catalog",
            address
        ));
    };
    if *owner_space != command.space || owner_namespace != &command.namespace {
        return Err(format!(
            "delegated execution owner '{}' has an incompatible command identity",
            address
        ));
    }
    let owner_identity =
        CommandIdentity::new(*owner_space, owner_namespace.as_deref(), owner_path.clone())
            .map_err(|error| format!("invalid delegated execution owner identity: {error}"))?;
    let command_identity = CommandIdentity::new(
        command.space,
        command.namespace.as_deref(),
        command.path.clone(),
    )
    .map_err(|error| format!("invalid delegated command identity: {error}"))?;
    if !owner_identity.is_true_ancestor_of(&command_identity) {
        return Err(format!(
            "delegated execution owner '{}' must be an ancestor of '{}'",
            address, command.address
        ));
    }
    if let Some((nested_address, _)) = entries.iter().find(|(_, candidate)| {
        let (space, namespace, path, _, declares_native) = candidate;
        *declares_native
            && CommandIdentity::new(*space, namespace.as_deref(), path.clone()).is_ok_and(
                |nested| {
                    owner_identity.is_true_ancestor_of(&nested)
                        && nested.is_true_ancestor_of(&command_identity)
                },
            )
    }) {
        return Err(format!(
            "delegated command '{}' cannot cross nested native owner '{}' to reach '{}'",
            command.address, nested_address, address
        ));
    }
    if adapter.as_deref() != Some("native") {
        return Err(format!(
            "delegated execution owner '{}' must declare native execution",
            address
        ));
    }
    Ok(address.clone())
}

fn read_local_help(
    command_directory: &Path,
    entry_name: &str,
    address: &str,
    language: EntryLanguage,
) -> io::Result<Option<HelpDocument>> {
    let directories = named_directories(command_directory, "_help")?;
    if directories.len() > 1 {
        return invalid_data(format!(
            "help directory name collision below '{}'",
            command_directory.display()
        ));
    }
    let Some(help_directory) = directories.first() else {
        return Ok(None);
    };
    if help_directory.name != "_help" {
        return invalid_data(format!(
            "non-canonical help directory '{}'; expected '_help'",
            help_directory.name
        ));
    }
    if help_directory.reparse_point {
        return invalid_data(format!(
            "help directory cannot be a reparse point: {}",
            help_directory.path.display()
        ));
    }

    let files = directory_files(&help_directory.path)?;
    let mut help_file = find_help_file(&help_directory.path, &files, language.help_file_name())?;
    if help_file.is_none() && language == EntryLanguage::En {
        help_file = find_help_file(&help_directory.path, &files, "zh-CN.txt")?;
    }
    let Some(help_file) = help_file else {
        return Ok(None);
    };
    if help_file.reparse_point {
        return invalid_data(format!(
            "help file cannot be a reparse point: {}",
            help_file.path.display()
        ));
    }

    let text = fs::read_to_string(&help_file.path)?;
    let summary = text
        .lines()
        .find(|line| !line.trim().is_empty())
        .map(str::trim)
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("help file is empty: {}", help_file.path.display()),
            )
        })?;
    let invocation = if address.is_empty() {
        entry_name.to_owned()
    } else {
        format!("{entry_name} {address}")
    };

    Ok(Some(HelpDocument {
        summary: expand_help(summary, entry_name, address, &invocation),
        text: expand_help(&text, entry_name, address, &invocation),
    }))
}

fn find_help_file<'a>(
    help_directory: &Path,
    files: &'a [FileCandidate],
    expected_name: &str,
) -> io::Result<Option<&'a FileCandidate>> {
    let matches: Vec<&FileCandidate> = files
        .iter()
        .filter(|file| file.name.eq_ignore_ascii_case(expected_name))
        .collect();
    if matches.len() > 1 {
        return invalid_data(format!(
            "help file name collision below '{}'",
            help_directory.display()
        ));
    }
    let Some(help_file) = matches.first().copied() else {
        return Ok(None);
    };
    if help_file.name != expected_name {
        return invalid_data(format!(
            "non-canonical help file '{}'; expected '{expected_name}'",
            help_file.name
        ));
    }
    Ok(Some(help_file))
}

fn expand_help(text: &str, entry_name: &str, address: &str, invocation: &str) -> String {
    text.replace("{{COMMAND}}", entry_name)
        .replace("{{ADDRESS}}", address)
        .replace("{{INVOCATION}}", invocation)
}

fn invalid_data<T>(message: String) -> io::Result<T> {
    Err(io::Error::new(io::ErrorKind::InvalidData, message))
}

#[cfg(test)]
mod tests;
