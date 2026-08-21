use swawkit_proj_protocol::{
    CommandRequirement, FacetExecution, FacetRoute, ResourceFacetKind, ResourceRoute,
};

use super::super::model::LoadedFacet;
use crate::catalog::{CommandAdapter, entry::ResolvedEntry};

pub(super) struct CompiledExecute {
    pub(super) entry: Option<ResolvedEntry>,
    pub(super) delegate_owner: Option<String>,
    pub(super) declares_native: bool,
}

pub(super) fn compile_requirements(
    facet: &LoadedFacet,
    diagnostics: &mut Vec<String>,
) -> Vec<CommandRequirement> {
    let Some(manifest) = &facet.requirements else {
        return Vec::new();
    };
    manifest
        .requirements
        .iter()
        .filter_map(|requirement| {
            let provider = ResourceRoute::parse(&requirement.provider)
                .map_err(|error| error.to_string())
                .and_then(|route| super::super::command_identity_for_resource_route(&route));
            match provider {
                Ok(provider) => Some(CommandRequirement {
                    provider: provider.address(),
                    export: requirement.export.clone(),
                }),
                Err(error) => {
                    diagnostics.push(format!(
                        "Facet requirement provider '{}' is not a backing Command Resource: {error}",
                        requirement.provider
                    ));
                    None
                }
            }
        })
        .collect()
}

pub(super) fn compile_execute_facet(
    facet: &LoadedFacet,
    diagnostics: &mut Vec<String>,
) -> CompiledExecute {
    if facet.kind != ResourceFacetKind::Operation {
        diagnostics.push(format!(
            "CLI execute Facet '{}' must be an operation",
            facet.route
        ));
        return unavailable();
    }
    if facet.view.is_some()
        || facet.resource_kind.is_some()
        || !facet.resources.is_empty()
        || !facet.templates.is_empty()
    {
        let templates = facet
            .templates
            .iter()
            .map(|template| {
                format!(
                    "{}:{:?}:{}:local={}:declared={}",
                    template.id,
                    template.kind,
                    template.directory.display(),
                    template.local_entry.is_some(),
                    template.execution.is_some() || template.requirements.is_some()
                )
            })
            .collect::<Vec<_>>()
            .join(",");
        diagnostics.push(format!(
            "CLI execute Facet '{}' cannot own Collection or View declarations ({templates})",
            facet.route,
        ));
        return unavailable();
    }
    let (entry, delegate_owner, declares_native) = match (&facet.local_entry, &facet.execution) {
        (Some(entry), None) => (local_entry(entry, diagnostics), None, false),
        (None, Some(execution)) => match &execution.implementation {
            FacetExecution::Core { handler } => (
                Some(ResolvedEntry::declared(
                    super::super::EXECUTION_FILE,
                    CommandAdapter::Core,
                    Some(handler.clone()),
                    None,
                )),
                None,
                false,
            ),
            FacetExecution::Runtime { product } => (
                Some(ResolvedEntry::declared(
                    super::super::EXECUTION_FILE,
                    CommandAdapter::Runtime,
                    None,
                    Some(product.clone()),
                )),
                None,
                false,
            ),
            FacetExecution::Native => (
                Some(ResolvedEntry::declared(
                    super::super::EXECUTION_FILE,
                    CommandAdapter::Native,
                    None,
                    None,
                )),
                None,
                true,
            ),
            FacetExecution::NativeDelegate {
                owner: owner_reference,
            } => {
                let owner_identity = FacetRoute::parse(owner_reference)
                    .map_err(|error| error.to_string())
                    .and_then(|owner| {
                        super::super::command_identity_for_resource_route(owner.resource())
                    });
                match owner_identity {
                    Ok(owner) => (
                        Some(ResolvedEntry::declared(
                            super::super::EXECUTION_FILE,
                            CommandAdapter::Delegate,
                            None,
                            None,
                        )),
                        Some(owner.address()),
                        false,
                    ),
                    Err(error) => {
                        diagnostics.push(format!(
                            "execute Facet delegate '{}' is invalid: {error}",
                            owner_reference
                        ));
                        (None, None, false)
                    }
                }
            }
            FacetExecution::Invoke { .. } => {
                diagnostics.push("a CLI execute Facet cannot use invoke execution".to_owned());
                (None, None, false)
            }
        },
        (None, None) => {
            diagnostics.push(format!(
                "execute Facet '{}' has no implementation",
                facet.route
            ));
            (None, None, false)
        }
        (Some(_), Some(_)) => {
            diagnostics.push(format!(
                "execute Facet '{}' has multiple implementations",
                facet.route
            ));
            (None, None, false)
        }
    };
    CompiledExecute {
        entry,
        delegate_owner,
        declares_native,
    }
}

fn unavailable() -> CompiledExecute {
    CompiledExecute {
        entry: None,
        delegate_owner: None,
        declares_native: false,
    }
}

fn local_entry(name: &str, diagnostics: &mut Vec<String>) -> Option<ResolvedEntry> {
    let (name, adapter) = match name {
        "run.exe" => ("run.exe", CommandAdapter::Exe),
        "run.ts" => ("run.ts", CommandAdapter::Bun),
        "run.py" => ("run.py", CommandAdapter::Python),
        "run.ps1" => ("run.ps1", CommandAdapter::Pwsh),
        "run.cmd" => ("run.cmd", CommandAdapter::Cmd),
        unknown => {
            diagnostics.push(format!("unsupported local Facet entry '{unknown}'"));
            return None;
        }
    };
    Some(ResolvedEntry {
        name,
        adapter,
        handler: None,
        product: None,
    })
}
