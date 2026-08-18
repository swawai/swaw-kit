use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use crate::catalog::{
    CatalogSnapshot, CommandAdapter, CommandNode, CommandSpace, MODULE_CONTRACT_FILE,
};
use crate::command::{
    CommandError, CommandExecutionContext, CommandResult, ResolvedCommand,
    catalog_command_data_root_from_roots,
};
use crate::development::setup::storage::ExclusiveFileLock;

mod release;
mod single;
mod storage;

use storage::{ensure_data_root, ensure_descendant, read_regular_file};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NativeCommandPublication {
    pub release_id: String,
    pub changed: bool,
}

pub(crate) struct NativeCommandResolution {
    pub(crate) executable: PathBuf,
    pub(crate) owner_address: String,
    pub(crate) owner_directory: PathBuf,
    pub(crate) owner_data_root: PathBuf,
}

pub fn instantiate(
    data_root: &Path,
    catalog: &CatalogSnapshot,
    command: &CommandNode,
) -> Result<NativeCommandPublication, String> {
    let cargo = managed_cargo()?;
    instantiate_with_cargo(data_root, catalog, command, &cargo)
}

pub fn instantiation_target_address(command: &CommandNode) -> Result<&str, String> {
    match command.adapter.as_deref() {
        Some("native") => Ok(&command.address),
        Some("delegate") => command.native_owner.as_deref().ok_or_else(|| {
            format!(
                "delegated command '{}' has no validated native owner",
                command.address
            )
        }),
        _ => Err(format!(
            "command '{}' is not an instantiable native module or delegated port",
            command.address
        )),
    }
}

fn instantiate_with_cargo(
    data_root: &Path,
    catalog: &CatalogSnapshot,
    command: &CommandNode,
    cargo: &Path,
) -> Result<NativeCommandPublication, String> {
    let owner = native_owner(catalog, command)?;
    ensure_data_root(data_root)?;

    let module_data_root = catalog_command_data_root_from_roots(data_root, owner)
        .map_err(|error| error.to_string())?;
    ensure_descendant(data_root, &module_data_root, "native module DataRoot")?;
    let native_root = ensure_descendant(
        &module_data_root,
        &module_data_root.join("_native"),
        "native module runtime",
    )?;
    let _lock = acquire_build_lock(&native_root)?;
    let source_before = release::source_contract(catalog, owner)?;
    let candidate = build_candidate(&native_root, owner, cargo)?;
    let source_after = release::source_contract(catalog, owner)?;
    if source_after != source_before {
        return Err(format!(
            "native module '{}' source manifests changed during compilation",
            owner.address
        ));
    }
    release::validate_candidate(&candidate.path, owner, &source_after)?;
    let release_document =
        release::release_document(&owner.address, source_after, &candidate.bytes)?;
    single::publish(&native_root, &candidate.bytes, &release_document)
}

fn native_owner<'a>(
    catalog: &'a CatalogSnapshot,
    command: &CommandNode,
) -> Result<&'a CommandNode, String> {
    if command.space == CommandSpace::System {
        return Err(format!(
            "System command '{}' cannot be instantiated as a Module",
            command.address
        ));
    }
    let owner_address = instantiation_target_address(command)?;
    let owner = catalog
        .commands
        .iter()
        .find(|candidate| candidate.address == owner_address)
        .ok_or_else(|| {
            format!(
                "native owner '{}' for command '{}' is missing from the Catalog",
                owner_address, command.address
            )
        })?;
    validate_native_command(owner)?;
    Ok(owner)
}

fn validate_native_command(command: &CommandNode) -> Result<(), String> {
    if command.space != CommandSpace::Module
        || command.entry.as_deref() != Some(MODULE_CONTRACT_FILE)
        || command.adapter.as_deref() != Some("native")
    {
        return Err(format!(
            "command '{}' is not an instantiable native module",
            command.address
        ));
    }
    Ok(())
}

fn acquire_build_lock(module_data_root: &Path) -> Result<ExclusiveFileLock, String> {
    let locks = ensure_descendant(
        module_data_root,
        &module_data_root.join("locks"),
        "native module locks",
    )?;
    ExclusiveFileLock::acquire(&locks.join("instantiate.lock"), Duration::from_secs(600))
        .map_err(|error| format!("cannot acquire native module build lock: {error}"))
}

struct NativeCandidate {
    path: PathBuf,
    bytes: Vec<u8>,
}

fn build_candidate(
    module_data_root: &Path,
    command: &CommandNode,
    cargo: &Path,
) -> Result<NativeCandidate, String> {
    let manifest = command.directory.join("Cargo.toml");
    read_regular_file(&manifest, "native module Cargo manifest")
        .map_err(|error| error.to_string())?;
    let work = ensure_descendant(
        module_data_root,
        &module_data_root.join("work/cargo-target"),
        "native module build directory",
    )?;
    let status = Command::new(cargo)
        .arg("build")
        .arg("--locked")
        .arg("--release")
        .arg("--manifest-path")
        .arg(&manifest)
        .arg("--target-dir")
        .arg(&work)
        .current_dir(&command.directory)
        .status()
        .map_err(|error| format!("cannot start managed Cargo '{}': {error}", cargo.display()))?;
    if !status.success() {
        return Err(format!(
            "native module '{}' failed to compile with exit code {}",
            command.address,
            status.code().unwrap_or(1)
        ));
    }
    let candidate = work.join("release/run.exe");
    let bytes = read_regular_file(&candidate, "compiled native command")
        .map_err(|error| error.to_string())?;
    if bytes.is_empty() {
        return Err(format!(
            "compiled native command is empty: {}",
            candidate.display()
        ));
    }
    Ok(NativeCandidate {
        path: candidate,
        bytes,
    })
}

#[cfg(test)]
fn resolve_executable(
    module_data_root: &Path,
    owner: &str,
    source: &release::SourceContract,
) -> CommandResult<PathBuf> {
    let native_root = resolve_native_root(module_data_root)?;
    single::resolve(&native_root, owner, source)
}

#[cfg(test)]
pub(crate) fn publish_test_executable(
    module_data_root: &Path,
    catalog: &CatalogSnapshot,
    owner: &CommandNode,
    bytes: &[u8],
) -> Result<NativeCommandPublication, String> {
    let source = release::source_contract(catalog, owner)?;
    let document = release::release_document(&owner.address, source, bytes)?;
    publish_executable(module_data_root, bytes, &document)
}

#[cfg(test)]
fn publish_executable(
    module_data_root: &Path,
    bytes: &[u8],
    release_document: &[u8],
) -> Result<NativeCommandPublication, String> {
    let native_root = ensure_descendant(
        module_data_root,
        &module_data_root.join("_native"),
        "native module runtime",
    )?;
    single::publish(&native_root, bytes, release_document)
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
    let owner_data_root = catalog_command_data_root_from_roots(&context.data_root, owner)?;
    let native_root = resolve_native_root(&owner_data_root)?;
    let source = release::source_contract(catalog, owner).map_err(CommandError::new)?;
    let executable = single::resolve(&native_root, &owner.address, &source)?;
    Ok(NativeCommandResolution {
        executable,
        owner_address,
        owner_directory: owner.directory.clone(),
        owner_data_root,
    })
}

fn resolve_native_root(module_data_root: &Path) -> CommandResult<PathBuf> {
    storage::checked_directory(
        &module_data_root.join("_native"),
        "native module runtime",
    )
    .map_err(|error| {
        CommandError::new(format!(
            "{error}. the module has not been instantiated; publish its run.exe export before execution"
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

fn managed_cargo() -> Result<PathBuf, String> {
    let rustc = env::var_os("RUSTC")
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            "managed Rust is disabled; enable it in the Entry Profile and run .dev/setup".to_owned()
        })?;
    managed_toolchain_cargo(&PathBuf::from(rustc))
}

fn managed_toolchain_cargo(rustc: &Path) -> Result<PathBuf, String> {
    if !rustc.is_absolute() {
        return Err("managed RUSTC must be absolute".to_owned());
    }
    if rustc.file_name() != Some(std::ffi::OsStr::new("rustc.exe")) {
        return Err(format!(
            "managed RUSTC must name rustc.exe: {}",
            rustc.display()
        ));
    }
    read_regular_file(rustc, "managed Rust compiler").map_err(|error| error.to_string())?;
    let cargo = rustc
        .parent()
        .expect("an absolute executable path has a parent")
        .join("cargo.exe");
    read_regular_file(&cargo, "managed Cargo").map_err(|error| error.to_string())?;
    Ok(cargo)
}

#[cfg(test)]
#[path = "native_command/tests.rs"]
mod tests;
