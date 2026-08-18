use std::collections::BTreeSet;
use std::path::Path;

use serde::Serialize;

use crate::catalog::{CatalogSnapshot, CommandNode, CommandSpace, ModuleRequirement};

mod publication;

use publication::inspect_publication;

pub const COMMAND_CHECK_PROTOCOL: &str = "swawkit.command-check/v1";
const MAX_DEPENDENCY_DEPTH: usize = 32;
const MAX_DEPENDENCY_ITEMS: usize = 512;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandCheckDocument {
    pub protocol: &'static str,
    pub command: CheckedCommand,
    pub dependencies: Vec<DependencyCheck>,
    pub ready: bool,
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
pub struct DependencyCheck {
    pub provider: String,
    pub export: String,
    pub contract: String,
    pub ready: bool,
    pub status: String,
    pub message: Option<String>,
    pub dependencies: Vec<DependencyCheck>,
}

pub fn inspect(
    data_root: &Path,
    entry_name: &str,
    snapshot: &CatalogSnapshot,
    target_address: &str,
) -> Result<CommandCheckDocument, String> {
    let target = resolve_target(snapshot, target_address)?;
    let dependencies = evaluate_dependencies(data_root, entry_name, snapshot, target)?;
    let ready = target.runnable && dependencies.iter().all(|dependency| dependency.ready);

    Ok(CommandCheckDocument {
        protocol: COMMAND_CHECK_PROTOCOL,
        command: CheckedCommand {
            address: target.address.clone(),
            space: target.space,
            namespace: target.namespace.clone(),
            runnable: target.runnable,
            adapter: target.adapter.clone(),
            diagnostic: target.diagnostic.clone(),
        },
        dependencies,
        ready,
    })
}

pub(crate) fn assert_dependencies_ready(
    data_root: &Path,
    entry_name: &str,
    snapshot: &CatalogSnapshot,
    target_address: &str,
) -> Result<(), String> {
    let target = resolve_target(snapshot, target_address)?;
    let dependencies = evaluate_dependencies(data_root, entry_name, snapshot, target)?;
    let failures = dependencies
        .iter()
        .filter(|dependency| !dependency.ready)
        .map(runtime_failure_summary)
        .collect::<Vec<_>>();
    if failures.is_empty() {
        Ok(())
    } else {
        Err(format!(
            "command dependencies are not ready for '{}': {}",
            target.address,
            failures.join("; ")
        ))
    }
}

fn evaluate_dependencies(
    data_root: &Path,
    entry_name: &str,
    snapshot: &CatalogSnapshot,
    target: &CommandNode,
) -> Result<Vec<DependencyCheck>, String> {
    let requirements = target
        .module
        .as_ref()
        .map(|module| module.requires.as_slice())
        .unwrap_or_default();
    let mut active = BTreeSet::from([target.address.clone()]);
    let mut budget = DependencyBudget::default();
    requirements
        .iter()
        .map(|requirement| {
            evaluate_dependency(
                data_root,
                entry_name,
                snapshot,
                requirement,
                0,
                &mut active,
                &mut budget,
            )
        })
        .collect()
}

fn evaluate_dependency(
    data_root: &Path,
    entry_name: &str,
    snapshot: &CatalogSnapshot,
    requirement: &ModuleRequirement,
    depth: usize,
    active: &mut BTreeSet<String>,
    budget: &mut DependencyBudget,
) -> Result<DependencyCheck, String> {
    budget.consume(requirement, depth)?;
    if !active.insert(requirement.provider.clone()) {
        return Ok(dependency_failure(
            requirement,
            "cycle",
            "module dependency cycle detected",
        ));
    }
    let Some(provider) = snapshot
        .commands
        .iter()
        .find(|command| command.address == requirement.provider && command.alias_of.is_none())
    else {
        active.remove(&requirement.provider);
        return Ok(dependency_failure(
            requirement,
            "provider-missing",
            "provider command is absent from the Catalog",
        ));
    };
    let declared = provider.module.as_ref().is_some_and(|module| {
        module.provides.iter().any(|provision| {
            provision.id == requirement.export && provision.contract == requirement.contract
        })
    });
    if !declared {
        active.remove(&requirement.provider);
        return Ok(dependency_failure(
            requirement,
            "contract-not-declared",
            "provider does not declare the required contract",
        ));
    }

    let publication = inspect_publication(data_root, entry_name, provider);
    let dependencies = provider
        .module
        .as_ref()
        .map(|module| {
            module
                .requires
                .iter()
                .map(|child| {
                    evaluate_dependency(
                        data_root,
                        entry_name,
                        snapshot,
                        child,
                        depth + 1,
                        active,
                        budget,
                    )
                })
                .collect::<Result<Vec<_>, _>>()
        })
        .transpose()?
        .unwrap_or_default();
    active.remove(&requirement.provider);

    let dependencies_ready = dependencies.iter().all(|dependency| dependency.ready);
    let ready = provider.runnable && publication.ready && dependencies_ready;
    let (status, message) = if !provider.runnable {
        (
            "provider-not-runnable".to_owned(),
            Some(
                provider
                    .diagnostic
                    .clone()
                    .unwrap_or_else(|| "provider command is not runnable".to_owned()),
            ),
        )
    } else if !publication.ready {
        (publication.status, publication.message)
    } else if !dependencies_ready {
        ("dependency-not-ready".to_owned(), None)
    } else {
        ("ready".to_owned(), None)
    };
    Ok(DependencyCheck {
        provider: requirement.provider.clone(),
        export: requirement.export.clone(),
        contract: requirement.contract.clone(),
        ready,
        status,
        message,
        dependencies,
    })
}

#[derive(Default)]
struct DependencyBudget {
    items: usize,
}

impl DependencyBudget {
    fn consume(&mut self, requirement: &ModuleRequirement, depth: usize) -> Result<(), String> {
        if depth > MAX_DEPENDENCY_DEPTH {
            return Err(format!(
                "command dependency depth exceeds maximum {MAX_DEPENDENCY_DEPTH} at '{}#{}'",
                requirement.provider, requirement.export
            ));
        }
        if self.items >= MAX_DEPENDENCY_ITEMS {
            return Err(format!(
                "command dependency graph exceeds maximum {MAX_DEPENDENCY_ITEMS} items at '{}#{}'",
                requirement.provider, requirement.export
            ));
        }
        self.items += 1;
        Ok(())
    }
}

fn runtime_failure_summary(dependency: &DependencyCheck) -> String {
    if let Some(message) = &dependency.message {
        return format!(
            "{}#{} -> {} [{}]: {message}",
            dependency.provider, dependency.export, dependency.contract, dependency.status
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
        "{}#{} -> {} [{}]: provider dependency is not ready",
        dependency.provider, dependency.export, dependency.contract, dependency.status
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
        dependencies: Vec::new(),
    }
}

#[cfg(test)]
mod tests;
