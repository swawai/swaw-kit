use std::path::{Path, PathBuf};

use swawkit_proj_protocol::{
    CommandIdentity, ExecutionContract, ExecutionContractCommand, ExecutionSemantics,
    ModuleProvision as ProtocolProvision, ModuleRequirement as ProtocolRequirement,
    command_data_root as identity_data_root, native_command_root,
};
#[cfg(test)]
use swawkit_proj_protocol::{
    CommandRelease, command_release_document, command_release_id, revision,
};

use crate::catalog::{CatalogSnapshot, CommandAdapter, CommandNode};
use crate::command::{CommandError, CommandExecutionContext, CommandResult, ResolvedCommand};

mod single;
mod storage;

pub(crate) struct NativeCommandResolution {
    pub(crate) executable: PathBuf,
    pub(crate) owner_address: String,
    pub(crate) owner_directory: PathBuf,
    pub(crate) owner_data_root: PathBuf,
}

pub(crate) fn resolve_command_executable(
    context: &CommandExecutionContext,
    catalog: &CatalogSnapshot,
    command: &ResolvedCommand,
) -> CommandResult<NativeCommandResolution> {
    let owner_address = instantiation_target(command)?;
    let owner = catalog
        .commands
        .iter()
        .find(|candidate| candidate.address == owner_address)
        .ok_or_else(|| {
            CommandError::new(format!(
                "Catalog invariant failed: native owner '{}' is unavailable",
                owner_address
            ))
        })?;
    let contract = execution_contract(catalog, owner).map_err(CommandError::new)?;
    let contract_revision = contract.revision().map_err(|error| {
        CommandError::new(format!("cannot derive native execution contract: {error}"))
    })?;
    let commands = contract.delegated_commands();
    let owner_identity =
        CommandIdentity::new(owner.space, owner.namespace.as_deref(), owner.path.clone()).map_err(
            |error| {
                CommandError::new(format!(
                    "Catalog invariant failed for native owner '{}': {error}",
                    owner.address
                ))
            },
        )?;
    if owner_identity.address() != owner.address {
        return Err(CommandError::new(format!(
            "Catalog invariant failed for native owner '{}': noncanonical address",
            owner.address
        )));
    }
    let owner_data_root = identity_data_root(&context.data_root, &owner_identity);
    let native_root =
        checked_native_root(&native_command_root(&context.data_root, &owner_identity))?;
    let executable = single::resolve(&native_root, &owner.address, &contract_revision, &commands)?;
    Ok(NativeCommandResolution {
        executable,
        owner_address,
        owner_directory: owner.directory.clone(),
        owner_data_root,
    })
}

fn checked_native_root(native_root: &Path) -> CommandResult<PathBuf> {
    storage::checked_directory(
        native_root,
        "native command runtime",
    )
    .map_err(|error| {
        CommandError::new(format!(
            "{error}. the native owner has not been instantiated; publish its run.exe before execution"
        ))
    })
}

pub(crate) fn instantiation_target(command: &ResolvedCommand) -> CommandResult<String> {
    match command.adapter {
        CommandAdapter::Native => Ok(command.address.clone()),
        CommandAdapter::Delegate => command.native_owner.clone().ok_or_else(|| {
            CommandError::new(format!(
                "Catalog invariant failed: delegated command '{}' has no native owner",
                command.address
            ))
        }),
        _ => Err(CommandError::new(format!(
            "command '{}' does not use a native entry",
            command.address
        ))),
    }
}

fn execution_contract(
    catalog: &CatalogSnapshot,
    owner: &CommandNode,
) -> Result<ExecutionContract, String> {
    if owner.adapter.as_deref() != Some("native")
        || owner.native_owner.as_deref() != Some(owner.address.as_str())
    {
        return Err(format!(
            "command '{}' is not a validated native owner",
            owner.address
        ));
    }
    let members = catalog
        .commands
        .iter()
        .filter(|command| {
            command.alias_of.is_none()
                && (command.address == owner.address
                    || command.native_owner.as_deref() == Some(owner.address.as_str()))
        })
        .map(|command| execution_contract_command(command, &owner.address))
        .collect::<Result<Vec<_>, _>>()?;
    ExecutionContract::new(&owner.address, members)
        .map_err(|error| format!("invalid native execution contract: {error}"))
}

fn execution_contract_command(
    command: &CommandNode,
    owner: &str,
) -> Result<ExecutionContractCommand, String> {
    let module = command.module.as_ref().ok_or_else(|| {
        format!(
            "native release member '{}' has no canonical module contract",
            command.address
        )
    })?;
    let execution = match command.adapter.as_deref() {
        Some("native") if command.address == owner => ExecutionSemantics::Native,
        Some("delegate") if command.native_owner.as_deref() == Some(owner) => {
            ExecutionSemantics::Delegate {
                owner: owner.to_owned(),
            }
        }
        _ => {
            return Err(format!(
                "native release member '{}' has incompatible execution",
                command.address
            ));
        }
    };
    Ok(ExecutionContractCommand {
        address: command.address.clone(),
        execution,
        requires: module
            .requires
            .iter()
            .map(|requirement| ProtocolRequirement {
                provider: requirement.provider.clone(),
                export: requirement.export.clone(),
                contract: requirement.contract.clone(),
            })
            .collect(),
        provides: module
            .provides
            .iter()
            .map(|provision| ProtocolProvision {
                id: provision.id.clone(),
                contract: provision.contract.clone(),
            })
            .collect(),
    })
}

#[cfg(test)]
pub(crate) fn publish_test_executable(
    owner_data_root: &Path,
    catalog: &CatalogSnapshot,
    owner: &CommandNode,
    bytes: &[u8],
) -> Result<PathBuf, String> {
    use std::fs;

    let contract = execution_contract(catalog, owner)?;
    let release = CommandRelease::new(
        &owner.address,
        revision(b"core-native-test-build-input"),
        contract
            .revision()
            .map_err(|error| format!("cannot derive native execution contract: {error}"))?,
        contract.delegated_commands(),
        bytes,
    )
    .map_err(|error| error.to_string())?;
    let document = command_release_document(&release).map_err(|error| error.to_string())?;
    let release_id = command_release_id(&document);
    let release_root = owner_data_root
        .join("_native/export/command/releases")
        .join(&release_id);
    fs::create_dir_all(&release_root).map_err(|error| {
        format!(
            "cannot create native test release '{}': {error}",
            release_root.display()
        )
    })?;
    fs::write(release_root.join("run.exe"), bytes).map_err(|error| error.to_string())?;
    fs::write(release_root.join("swawkit.release.json"), document)
        .map_err(|error| error.to_string())?;
    let selector = owner_data_root.join("_native/export/command/current");
    fs::write(&selector, format!("{release_id}\n")).map_err(|error| error.to_string())?;
    Ok(release_root.join("run.exe"))
}

#[cfg(test)]
fn resolve_test_executable(
    owner_data_root: &Path,
    catalog: &CatalogSnapshot,
    owner: &CommandNode,
) -> CommandResult<PathBuf> {
    let contract = execution_contract(catalog, owner).map_err(CommandError::new)?;
    let revision = contract
        .revision()
        .map_err(|error| CommandError::new(error.to_string()))?;
    single::resolve(
        &checked_native_root(&owner_data_root.join("_native"))?,
        &owner.address,
        &revision,
        &contract.delegated_commands(),
    )
}

#[cfg(test)]
#[path = "native_command/tests.rs"]
mod tests;
