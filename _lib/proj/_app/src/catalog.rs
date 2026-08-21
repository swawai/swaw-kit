use crate::{
    context::EntryContext,
    entry_config::{EntryConfig, EntryLanguage},
};
use serde::Serialize;
use std::collections::VecDeque;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use swawkit_proj_protocol::CommandIdentity;

mod address;
mod declaration;
mod entry;
mod facet;
mod filesystem;
mod identity;
mod native_owner;
mod resource_kind;
mod resource_loader;
mod route;

pub use crate::facet::{Facet, FacetKind, FacetRenderer, FacetResolver};
use address::child_address;
pub(crate) use entry::{CommandAdapter, resolve_entry};
use facet::resolve_command_facets;
pub(crate) use filesystem::named_directories;
use filesystem::{
    FileCandidate, absolute_path, assert_command_root, child_directories, directory_files,
};
use identity::CommandId;
pub use identity::CommandSpace;
use native_owner::resolve_native_owners;
use resource_kind::resolve_resource_kinds;
pub(crate) use route::{
    PlannedFacetRoute, PlannedResourceRoute, command_for_resource_route, plan_facet_route,
};
pub use swawkit_proj_protocol::{CommandProvision, CommandRequirement};

pub const CATALOG_PROTOCOL: &str = "swawkit.command-catalog/v24";

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
                declaration: read_pending_declaration(&system_path),
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
                        declaration: read_pending_declaration(&path),
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
        resolve_resource_kinds(&mut commands);
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
        let scanned = scan_node(&current, entry_name, language);
        commands.push(scanned.command);
        if let Some(children) = scanned.resource_children {
            pending.extend(children);
            continue;
        }
        for child in child_directories(&current.path)? {
            let Some(child_command) = child_address(&current, &child.name) else {
                continue;
            };
            let declaration = read_pending_declaration(&child.path);
            if !matches!(declaration, PendingDeclaration::Absent) {
                pending.push_back(PendingDirectory {
                    path: child.path,
                    id: child_command.id,
                    declaration,
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
    #[serde(skip)]
    pub(crate) requirements: Vec<CommandRequirement>,
    #[serde(skip)]
    pub(crate) provisions: Vec<CommandProvision>,
    #[serde(skip)]
    pub(crate) delegate_owner: Option<String>,
    #[serde(skip)]
    pub(crate) declares_native: bool,
    #[serde(skip)]
    pub(crate) declared_facets: Vec<declaration::FacetDeclaration>,
    #[serde(skip)]
    pub(crate) declared_resource_kinds: Vec<declaration::ResourceKindDeclaration>,
    pub help: Option<HelpDocument>,
    pub resource_kinds: Vec<crate::resource_kind::ResourceKind>,
    pub facets: Vec<Facet>,
    pub diagnostic: Option<String>,
    #[serde(skip)]
    pub(crate) authored_resource: bool,
    /// Retains the Help protocol state without expanding the public Web API.
    #[serde(skip)]
    pub help_diagnostic: Option<String>,
    #[serde(skip)]
    pub directory: PathBuf,
    #[serde(skip)]
    pub(crate) executor_directory: PathBuf,
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
    declaration: PendingDeclaration,
}

#[derive(Debug)]
enum PendingDeclaration {
    Absent,
    Resource,
    InvalidResource(String),
}

fn read_pending_declaration(path: &Path) -> PendingDeclaration {
    match resource_loader::has_resource_marker(path) {
        Ok(true) => PendingDeclaration::Resource,
        Ok(false) => PendingDeclaration::Absent,
        Err(error) => return PendingDeclaration::InvalidResource(error),
    }
}

#[derive(Debug)]
struct ChildCommand {
    id: CommandId,
}

struct ScannedNode {
    command: CommandNode,
    /// `Some` means the Resource Loader owns traversal, including the empty/error case.
    resource_children: Option<Vec<PendingDirectory>>,
}

fn scan_node(pending: &PendingDirectory, entry_name: &str, language: EntryLanguage) -> ScannedNode {
    let address = pending.id.address();
    let mut diagnostics = Vec::new();
    if let PendingDeclaration::InvalidResource(error) = &pending.declaration {
        diagnostics.push(error.clone());
    }
    let is_resource = matches!(&pending.declaration, PendingDeclaration::Resource);
    let mut requirements = Vec::new();
    let mut provisions = Vec::new();
    let mut delegate_owner = None;
    let mut declares_native = false;
    let mut declared_facets = Vec::new();
    let mut declared_resource_kinds = Vec::new();
    let resource_owns_traversal = matches!(
        &pending.declaration,
        PendingDeclaration::Resource | PendingDeclaration::InvalidResource(_)
    );
    let resource_command = if is_resource {
        let reference = CommandIdentity::new(
            pending.id.space,
            pending.id.namespace.as_deref(),
            pending.id.path.clone(),
        )
        .map_err(|error| error.to_string())
        .and_then(|identity| resource_loader::resource_route_for_command(&identity));
        match reference {
            Ok(reference) => Some(resource_loader::load_command_resource(
                &pending.path,
                reference,
                language,
            )),
            Err(error) => {
                diagnostics.push(error);
                None
            }
        }
    } else {
        None
    };
    let mut resource_children = resource_owns_traversal.then(Vec::new);
    let (local_entry, command_directory) = if let Some(resource) = resource_command {
        diagnostics.extend(resource.diagnostics);
        requirements = resource.requirements;
        provisions = resource.provisions;
        delegate_owner = resource.delegate_owner;
        declares_native = resource.declares_native;
        declared_facets = resource.facets;
        declared_resource_kinds = resource.resource_kinds;
        if let Some(pending_children) = resource_children.as_mut() {
            for child in resource.children {
                let Some(id) = pending.id.child(&child.selector) else {
                    diagnostics.push(format!(
                        "subcommands selector '{}' cannot become a Command identity",
                        child.selector
                    ));
                    continue;
                };
                pending_children.push(PendingDirectory {
                    declaration: read_pending_declaration(&child.directory),
                    path: child.directory,
                    id,
                });
            }
        }
        (resource.entry, resource.execution_directory)
    } else if is_resource {
        (None, pending.path.clone())
    } else {
        let entry = match resolve_entry(&pending.path) {
            Ok(entry) => entry,
            Err(error) => {
                diagnostics.push(error.to_string());
                None
            }
        };
        (entry, pending.path.clone())
    };
    let entry = local_entry;
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
        entry => entry,
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
    let command = CommandNode {
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
        requirements,
        provisions,
        delegate_owner,
        declares_native,
        declared_facets,
        declared_resource_kinds,
        help,
        resource_kinds: Vec::new(),
        facets: Vec::new(),
        diagnostic: (!diagnostics.is_empty()).then(|| diagnostics.join("; ")),
        authored_resource: is_resource,
        help_diagnostic,
        directory: pending.path.clone(),
        executor_directory: command_directory,
        native_owner: None,
    };
    ScannedNode {
        command,
        resource_children,
    }
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
