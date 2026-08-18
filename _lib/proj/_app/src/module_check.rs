use std::collections::BTreeSet;
use std::path::Path;

use serde::Serialize;

use crate::catalog::{
    CatalogSnapshot, CommandNode, CommandSpace, ModuleProvision, ModuleRequirement,
};
use crate::command::{GuardPlan, ResolvedCommand};
use crate::context::EntryContext;
use crate::profile::EntryProfile;

mod publication;

use publication::{inspect_publication, inspect_runtime_publication};

pub const MODULE_CHECK_PROTOCOL: &str = "swawkit.module-check/v3";

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModuleCheckDocument {
    pub protocol: &'static str,
    pub command: CheckedCommand,
    pub guards: Vec<GuardCheck>,
    pub dependencies: Vec<DependencyCheck>,
    pub publications: Vec<PublicationCheck>,
    pub ok: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CheckedCommand {
    pub address: String,
    pub space: CommandSpace,
    pub namespace: Option<String>,
    pub runnable: bool,
    pub adapter: Option<String>,
    pub diagnostic: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GuardCheck {
    pub scope: &'static str,
    pub entry: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DependencyCheck {
    pub provider: String,
    pub export: String,
    pub contract: String,
    pub ready: bool,
    pub status: String,
    pub message: Option<String>,
    pub publication: Option<PublicationCheck>,
    pub dependencies: Vec<DependencyCheck>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PublicationCheck {
    pub provider: String,
    pub export: String,
    pub contract: String,
    pub ready: bool,
    pub status: String,
    pub message: Option<String>,
    pub state_path: Option<String>,
    pub export_root: Option<String>,
    pub exports: Vec<ExportItem>,
    pub exports_truncated: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct ExportItem {
    pub name: String,
    pub kind: &'static str,
}

pub fn inspect(
    context: &EntryContext,
    data_root: &Path,
    profile: Option<&EntryProfile>,
    snapshot: &CatalogSnapshot,
    target_address: &str,
) -> Result<ModuleCheckDocument, String> {
    let target = resolve_target(snapshot, target_address)?;
    let guards = inspect_guards(context, snapshot, target)?;
    let requirements = target
        .module
        .as_ref()
        .map(|module| module.requires.as_slice())
        .unwrap_or_default();
    let mut active = BTreeSet::from([target.address.clone()]);
    let dependencies = requirements
        .iter()
        .map(|requirement| {
            inspect_dependency(
                context,
                data_root,
                profile,
                snapshot,
                requirement,
                &mut active,
            )
        })
        .collect::<Vec<_>>();
    let provisions = target
        .module
        .as_ref()
        .map(|module| module.provides.as_slice())
        .unwrap_or_default();
    let publications = provisions
        .iter()
        .map(|provision| inspect_publication(context, data_root, profile, target, provision))
        .collect::<Vec<_>>();
    let ok = target.runnable
        && dependencies.iter().all(|dependency| dependency.ready)
        && publications.iter().all(|publication| publication.ready);

    Ok(ModuleCheckDocument {
        protocol: MODULE_CHECK_PROTOCOL,
        command: CheckedCommand {
            address: target.address.clone(),
            space: target.space,
            namespace: target.namespace.clone(),
            runnable: target.runnable,
            adapter: target.adapter.clone(),
            diagnostic: target.diagnostic.clone(),
        },
        guards,
        dependencies,
        publications,
        ok,
    })
}

pub(crate) fn preflight_dependencies(
    data_root: &Path,
    entry_name: &str,
    snapshot: &CatalogSnapshot,
    target_address: &str,
) -> Result<(), String> {
    let target = resolve_target(snapshot, target_address)?;
    let requirements = target
        .module
        .as_ref()
        .map(|module| module.requires.as_slice())
        .unwrap_or_default();
    let mut active = BTreeSet::from([target.address.clone()]);
    let dependencies = requirements
        .iter()
        .map(|requirement| {
            inspect_runtime_dependency(data_root, entry_name, snapshot, requirement, &mut active)
        })
        .collect::<Vec<_>>();
    let failures = dependencies
        .iter()
        .filter(|dependency| !dependency.ready)
        .map(runtime_failure_summary)
        .collect::<Vec<_>>();
    if failures.is_empty() {
        Ok(())
    } else {
        Err(format!(
            "module dependency preflight failed for '{}': {}",
            target.address,
            failures.join("; ")
        ))
    }
}

fn runtime_failure_summary(dependency: &DependencyCheck) -> String {
    let status = dependency
        .publication
        .as_ref()
        .filter(|publication| !publication.ready)
        .map(|publication| publication.status.as_str())
        .unwrap_or(dependency.status.as_str());
    if let Some(message) = &dependency.message {
        return format!(
            "{}#{} -> {} [{status}]: {message}",
            dependency.provider, dependency.export, dependency.contract
        );
    }
    if let Some(child) = dependency
        .dependencies
        .iter()
        .find(|dependency| !dependency.ready)
    {
        return format!(
            "{}#{} -> {} depends on {}",
            dependency.provider,
            dependency.export,
            dependency.contract,
            runtime_failure_summary(child)
        );
    }
    format!(
        "{}#{} -> {} [{status}]: provider publication is not ready",
        dependency.provider, dependency.export, dependency.contract
    )
}

fn resolve_target<'a>(
    snapshot: &'a CatalogSnapshot,
    address: &str,
) -> Result<&'a CommandNode, String> {
    let mut matches = snapshot
        .commands
        .iter()
        .filter(|command| command.address == address);
    let Some(target) = matches.next() else {
        return Err(format!("command not found: {address}"));
    };
    if matches.next().is_some() {
        return Err(format!("ambiguous command address: {address}"));
    }
    match target.alias_of.as_deref() {
        Some(canonical) => resolve_target(snapshot, canonical),
        None => Ok(target),
    }
}

fn inspect_guards(
    context: &EntryContext,
    snapshot: &CatalogSnapshot,
    command: &CommandNode,
) -> Result<Vec<GuardCheck>, String> {
    if !command.runnable {
        return Ok(Vec::new());
    }
    let resolved = ResolvedCommand::from_catalog(snapshot, &command.address)
        .map_err(|error| error.to_string())?;
    let plan = GuardPlan::discover(&context.command_root(), &resolved)
        .map_err(|error| error.to_string())?;
    Ok(plan
        .guards
        .into_iter()
        .map(|guard| GuardCheck {
            scope: guard.scope.as_str(),
            entry: guard
                .entry_path
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("<non-Unicode>")
                .to_owned(),
        })
        .collect())
}

fn inspect_dependency(
    context: &EntryContext,
    data_root: &Path,
    profile: Option<&EntryProfile>,
    snapshot: &CatalogSnapshot,
    requirement: &ModuleRequirement,
    active: &mut BTreeSet<String>,
) -> DependencyCheck {
    if !active.insert(requirement.provider.clone()) {
        return dependency_failure(requirement, "cycle", "module dependency cycle detected");
    }
    let Some(provider) = snapshot
        .commands
        .iter()
        .find(|command| command.address == requirement.provider && command.alias_of.is_none())
    else {
        active.remove(&requirement.provider);
        return dependency_failure(
            requirement,
            "provider-missing",
            "provider command is absent from the Catalog",
        );
    };
    let declared = provider.module.as_ref().is_some_and(|module| {
        module.provides.iter().any(|provision| {
            provision.id == requirement.export && provision.contract == requirement.contract
        })
    });
    if !declared {
        active.remove(&requirement.provider);
        return dependency_failure(
            requirement,
            "contract-not-declared",
            "provider does not declare the required contract",
        );
    }

    let publication = inspect_publication(
        context,
        data_root,
        profile,
        provider,
        &ModuleProvision {
            id: requirement.export.clone(),
            contract: requirement.contract.clone(),
        },
    );
    let dependencies = provider
        .module
        .as_ref()
        .map(|module| {
            module
                .requires
                .iter()
                .map(|child| {
                    inspect_dependency(context, data_root, profile, snapshot, child, active)
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    active.remove(&requirement.provider);
    let ready = provider.runnable
        && publication.ready
        && dependencies.iter().all(|dependency| dependency.ready);
    DependencyCheck {
        provider: requirement.provider.clone(),
        export: requirement.export.clone(),
        contract: requirement.contract.clone(),
        ready,
        status: if ready { "ready" } else { "not-ready" }.to_owned(),
        message: (!provider.runnable).then(|| {
            provider
                .diagnostic
                .clone()
                .unwrap_or_else(|| "provider command is not runnable".to_owned())
        }),
        publication: Some(publication),
        dependencies,
    }
}

fn inspect_runtime_dependency(
    data_root: &Path,
    entry_name: &str,
    snapshot: &CatalogSnapshot,
    requirement: &ModuleRequirement,
    active: &mut BTreeSet<String>,
) -> DependencyCheck {
    if !active.insert(requirement.provider.clone()) {
        return dependency_failure(requirement, "cycle", "module dependency cycle detected");
    }
    let Some(provider) = snapshot
        .commands
        .iter()
        .find(|command| command.address == requirement.provider && command.alias_of.is_none())
    else {
        active.remove(&requirement.provider);
        return dependency_failure(
            requirement,
            "provider-missing",
            "provider command is absent from the Catalog",
        );
    };
    let Some(provision) = provider.module.as_ref().and_then(|module| {
        module.provides.iter().find(|provision| {
            provision.id == requirement.export && provision.contract == requirement.contract
        })
    }) else {
        active.remove(&requirement.provider);
        return dependency_failure(
            requirement,
            "contract-not-declared",
            "provider does not declare the required contract",
        );
    };
    let publication = inspect_runtime_publication(data_root, entry_name, provider, provision);
    let dependencies = provider
        .module
        .as_ref()
        .map(|module| {
            module
                .requires
                .iter()
                .map(|child| {
                    inspect_runtime_dependency(data_root, entry_name, snapshot, child, active)
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    active.remove(&requirement.provider);
    let ready = provider.runnable
        && publication.ready
        && dependencies.iter().all(|dependency| dependency.ready);
    DependencyCheck {
        provider: requirement.provider.clone(),
        export: requirement.export.clone(),
        contract: requirement.contract.clone(),
        ready,
        status: if ready { "ready" } else { "not-ready" }.to_owned(),
        message: if provider.runnable {
            publication.message.clone()
        } else {
            Some(
                provider
                    .diagnostic
                    .clone()
                    .unwrap_or_else(|| "provider command is not runnable".to_owned()),
            )
        },
        publication: Some(publication),
        dependencies,
    }
}

fn dependency_failure(
    requirement: &ModuleRequirement,
    status: &str,
    message: &str,
) -> DependencyCheck {
    DependencyCheck {
        provider: requirement.provider.clone(),
        export: requirement.export.clone(),
        contract: requirement.contract.clone(),
        ready: false,
        status: status.to_owned(),
        message: Some(message.to_owned()),
        publication: None,
        dependencies: Vec::new(),
    }
}
