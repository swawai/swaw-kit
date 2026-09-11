mod execute;
mod facets;
mod subcommands;

use std::path::{Path, PathBuf};

use swawkit_proj_protocol::{CommandProvision, CommandRequirement, ResourceRoute};

use self::{
    execute::compile_execute_facet, facets::compile_authored_facets,
    subcommands::compile_subcommands,
};
use super::load_resource_tree;
use crate::{
    catalog::{
        declaration::{FacetDeclaration, ResourceKindDeclaration},
        entry::ResolvedEntry,
    },
    entry_config::EntryLanguage,
};

pub(in crate::catalog) struct ResourceCommandContract {
    pub(in crate::catalog) entry: Option<ResolvedEntry>,
    pub(in crate::catalog) execution_directory: PathBuf,
    pub(in crate::catalog) children: Vec<ResourceCommandChild>,
    pub(in crate::catalog) requirements: Vec<CommandRequirement>,
    pub(in crate::catalog) provisions: Vec<CommandProvision>,
    pub(in crate::catalog) delegate_owner: Option<String>,
    pub(in crate::catalog) declares_native: bool,
    pub(in crate::catalog) facets: Vec<FacetDeclaration>,
    pub(in crate::catalog) resource_kinds: Vec<ResourceKindDeclaration>,
    pub(in crate::catalog) diagnostics: Vec<String>,
}

pub(in crate::catalog) struct ResourceCommandChild {
    pub(in crate::catalog) selector: String,
    pub(in crate::catalog) directory: PathBuf,
}

pub(in crate::catalog) fn has_resource_marker(directory: &Path) -> Result<bool, String> {
    let snapshot = super::filesystem::DirectorySnapshot::open(directory)?;
    snapshot
        .protocol_file(super::RESOURCE_FILE, false)
        .map(|marker| marker.is_some())
}

pub(in crate::catalog) fn load_command_resource(
    directory: &Path,
    route: ResourceRoute,
    language: EntryLanguage,
) -> ResourceCommandContract {
    let load = load_resource_tree(directory, route);
    let mut diagnostics = load
        .diagnostics
        .into_iter()
        .map(|diagnostic| format!("{}: {}", diagnostic.path.display(), diagnostic.message))
        .collect::<Vec<_>>();
    let Some(resource) = load.resource else {
        return unavailable(directory, diagnostics);
    };
    if resource.kind != "command" {
        diagnostics.push(format!(
            "Resource '{}' has kind '{}'; a CLI command Resource must use kind 'command'",
            resource.route, resource.kind
        ));
        return unavailable(directory, diagnostics);
    }
    if resource.directory != directory {
        diagnostics.push("Resource Loader returned a mismatched source directory".to_owned());
    }
    if resource.selector
        != directory
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("root")
    {
        diagnostics.push("Resource Loader returned a mismatched selector".to_owned());
    }

    let execute = resource
        .facets
        .iter()
        .find(|facet| facet.route.facet() == "execute");
    let subcommands = compile_subcommands(&resource.facets, language, &mut diagnostics);
    let children = subcommands.children;
    let (mut facets, resource_kinds) =
        compile_authored_facets(&resource.facets, language, &mut diagnostics);
    if let Some(declaration) = subcommands.declaration {
        facets.insert(0, declaration);
    }
    let provisions = resource
        .exports
        .as_ref()
        .map(|manifest| {
            manifest
                .exports
                .iter()
                .map(|export| CommandProvision {
                    id: export.id.clone(),
                })
                .collect()
        })
        .unwrap_or_default();
    let Some(execute) = execute else {
        return ResourceCommandContract {
            entry: None,
            execution_directory: directory.to_path_buf(),
            children,
            requirements: Vec::new(),
            provisions,
            delegate_owner: None,
            declares_native: false,
            facets,
            resource_kinds,
            diagnostics,
        };
    };
    let compiled = compile_execute_facet(execute, &mut diagnostics);
    ResourceCommandContract {
        entry: compiled.entry,
        execution_directory: execute.directory.clone(),
        children,
        requirements: compiled.requirements,
        provisions,
        delegate_owner: compiled.delegate_owner,
        declares_native: compiled.declares_native,
        facets,
        resource_kinds,
        diagnostics,
    }
}

fn unavailable(directory: &Path, diagnostics: Vec<String>) -> ResourceCommandContract {
    ResourceCommandContract {
        entry: None,
        execution_directory: directory.to_path_buf(),
        children: Vec::new(),
        requirements: Vec::new(),
        provisions: Vec::new(),
        delegate_owner: None,
        declares_native: false,
        facets: Vec::new(),
        resource_kinds: Vec::new(),
        diagnostics,
    }
}
