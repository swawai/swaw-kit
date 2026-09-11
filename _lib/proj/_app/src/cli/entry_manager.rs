use std::ffi::OsString;

use serde::Serialize;
use swawkit_proj::{
    catalog::CatalogSnapshot,
    context::EntryContext,
    entry_manager::{EntryManager, EntryMutationDocument, EntryMutationOperation, EntryStatus},
};

use super::{CliError, control::resolve_control, write_output};

pub(super) fn dispatch(context: &EntryContext, argv: &[OsString]) -> Result<Option<i32>, CliError> {
    let Some(address) = argv.first() else {
        return Ok(None);
    };
    let address = address
        .to_str()
        .ok_or_else(|| CliError::new("command address is not valid Unicode"))?;
    if !matches!(
        address,
        ".entry/instances" | ".entry/instances/create" | ".entry/instances/migrate"
    ) {
        return Ok(None);
    }

    let snapshot = CatalogSnapshot::discover(context, None)
        .map_err(|error| CliError::new(format!("catalog discovery failed: {error}")))?;
    let command = resolve_control(&snapshot, address)?;
    let arguments = argv.get(1..).unwrap_or_default();
    let manager = EntryManager::new(context);
    let exit_code = match command.handler.as_deref() {
        Some("entry.instances") => show_inventory(address, arguments, &manager)?,
        Some("entry.instances.create") => mutate(address, arguments, &manager, Mutation::Create)?,
        Some("entry.instances.migrate") => mutate(address, arguments, &manager, Mutation::Migrate)?,
        Some(handler) => {
            return Err(CliError::new(format!(
                "unsupported Entry Manager Core command handler: {handler}"
            )));
        }
        None => {
            return Err(CliError::new(format!(
                "Catalog invariant failed for '{address}': Core command has no handler"
            )));
        }
    };
    Ok(Some(exit_code))
}

fn show_inventory(
    address: &str,
    arguments: &[OsString],
    manager: &EntryManager<'_>,
) -> Result<i32, CliError> {
    let json = parse_optional_json(address, arguments)?;
    let document = manager
        .inventory()
        .map_err(|error| CliError::new(error.to_string()))?;
    if json {
        write_serialized(&document, "Entry inventory")?;
    } else {
        let mut output = format!(
            "Entry Instances\nHome: {}\nCount: {}",
            document.swawkit_home,
            document.entries.len()
        );
        for entry in &document.entries {
            output.push_str(&format!(
                "\n{}\t{}\t{}",
                entry.entry_name,
                entry_status(entry.status),
                entry.data_root
            ));
        }
        write_output(&output)
            .map_err(|error| CliError::new(format!("cannot write CLI output: {error}")))?;
    }
    Ok(0)
}

#[derive(Clone, Copy)]
enum Mutation {
    Create,
    Migrate,
}

fn mutate(
    address: &str,
    arguments: &[OsString],
    manager: &EntryManager<'_>,
    operation: Mutation,
) -> Result<i32, CliError> {
    let (name, json) = parse_mutation_arguments(address, arguments)?;
    let document = match operation {
        Mutation::Create => manager.create(name),
        Mutation::Migrate => manager.migrate(name),
    }
    .map_err(|error| CliError::new(error.to_string()))?;
    if json {
        write_serialized(&document, "Entry mutation")?;
    } else {
        write_mutation_summary(&document)?;
    }
    Ok(0)
}

fn parse_optional_json(address: &str, arguments: &[OsString]) -> Result<bool, CliError> {
    match arguments {
        [] => Ok(false),
        [format] if format == "--json" => Ok(true),
        _ => Err(CliError::new(format!("usage: {address} [--json]"))),
    }
}

fn parse_mutation_arguments<'a>(
    address: &str,
    arguments: &'a [OsString],
) -> Result<(&'a str, bool), CliError> {
    let usage = || CliError::new(format!("usage: {address} <entry-name> [--json]"));
    let (name, json) = match arguments {
        [name] => (name, false),
        [name, format] if format == "--json" => (name, true),
        _ => return Err(usage()),
    };
    let name = name.to_str().ok_or_else(usage)?;
    Ok((name, json))
}

fn write_mutation_summary(document: &EntryMutationDocument) -> Result<(), CliError> {
    let action = match document.operation {
        EntryMutationOperation::Create => "Create",
        EntryMutationOperation::Migrate => "Migrate",
    };
    let result = if document.changed {
        "changed"
    } else {
        "unchanged"
    };
    let mut output = format!(
        "Entry {action}\nResult: {result}\nName: {}\nStatus: {}\nLauncher: {}\nDataRoot: {}",
        document.entry.entry_name,
        entry_status(document.entry.status),
        document.entry.entry_file,
        document.entry.data_root,
    );
    if let Some(release_id) = &document.entry.release_id {
        output.push_str("\nRelease: ");
        output.push_str(release_id);
    }
    write_output(&output)
        .map_err(|error| CliError::new(format!("cannot write CLI output: {error}")))
}

fn entry_status(status: EntryStatus) -> &'static str {
    match status {
        EntryStatus::Available => "available",
        EntryStatus::Ready => "ready",
        EntryStatus::LegacyMigrationRequired => "legacy-migration-required",
        EntryStatus::Incomplete => "incomplete",
        EntryStatus::Conflict => "conflict",
    }
}

fn write_serialized<T: Serialize>(document: &T, label: &str) -> Result<(), CliError> {
    let output = serde_json::to_string_pretty(document)
        .map_err(|error| CliError::new(format!("cannot serialize {label}: {error}")))?;
    write_output(&output)
        .map_err(|error| CliError::new(format!("cannot write CLI output: {error}")))
}
