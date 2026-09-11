use std::ffi::OsString;
use std::path::{Path, PathBuf};

use swawkit_proj::{
    catalog::{CatalogSnapshot, CommandNode, is_help_marker},
    context::EntryContext,
    core_command::config as core_config,
    data_root::ResolvedDataRoot,
    entry_config::{EntryConfigDocument, EntryConfigStore},
    help::render_help,
    runtime_cleanup,
    runtime_control::{self, HostAction, RuntimeStatusDocument},
};

use super::{CliError, complete_core_command, write_output};

fn is_early_control(address: &str) -> bool {
    [".entry", ".runtime"].iter().any(|root| {
        address == *root
            || address
                .strip_prefix(root)
                .is_some_and(|suffix| suffix.starts_with('/'))
    })
}

pub(super) fn dispatch_help_before_data_root(
    context: &EntryContext,
    argv: &[OsString],
) -> Result<Option<i32>, CliError> {
    let Some(address) = argv.first() else {
        return Ok(None);
    };
    let address = address
        .to_str()
        .ok_or_else(|| CliError::new("command address is not valid Unicode"))?;
    if !is_early_control(address) {
        return Ok(None);
    }
    let arguments = argv.get(1..).unwrap_or_default();
    if !matches!(arguments, [marker] if marker.to_str().is_some_and(is_help_marker)) {
        return Ok(None);
    }
    let resolved = super::resolve_owned_data_root(context).ok();
    let snapshot = control_catalog(context, resolved.as_ref())?;
    control_node(&snapshot, address)?;
    let output =
        render_help(&snapshot, address).map_err(|error| CliError::new(error.to_string()))?;
    write_output(&output)
        .map_err(|error| CliError::new(format!("cannot write CLI output: {error}")))?;
    Ok(Some(0))
}

pub(super) fn dispatch_runtime(
    context: &EntryContext,
    argv: &[OsString],
    resolved: &ResolvedDataRoot,
) -> Result<Option<i32>, CliError> {
    let Some(address) = argv.first() else {
        return Ok(None);
    };
    let address = address
        .to_str()
        .ok_or_else(|| CliError::new("command address is not valid Unicode"))?;
    if address != ".runtime"
        && !address
            .strip_prefix(".runtime")
            .is_some_and(|suffix| suffix.starts_with('/'))
    {
        return Ok(None);
    }
    let snapshot = control_catalog(context, Some(resolved))?;
    let arguments = argv.get(1..).unwrap_or_default();
    let command = resolve_control(&snapshot, address)?;

    match command.handler.as_deref() {
        Some("runtime.status") => Ok(Some(show_runtime_status(arguments, context)?)),
        Some("host.exit") => Ok(Some(request_host_action(
            address,
            arguments,
            context,
            HostAction::Exit,
        )?)),
        Some("host.restart") => Ok(Some(request_host_action(
            address,
            arguments,
            context,
            HostAction::Restart,
        )?)),
        Some("runtime.cleanup") => Ok(Some(cleanup_runtime(address, arguments, context)?)),
        _ => Ok(None),
    }
}

fn control_catalog(
    context: &EntryContext,
    resolved: Option<&ResolvedDataRoot>,
) -> Result<CatalogSnapshot, CliError> {
    let config_state = resolved
        .map(|resolved| EntryConfigStore::new(&context.swawkit_home, resolved.path()).read());
    CatalogSnapshot::discover(
        context,
        config_state.as_ref().and_then(|state| state.ready()),
    )
    .map_err(|error| CliError::new(format!("catalog discovery failed: {error}")))
}

pub(super) fn dispatch(
    snapshot: &CatalogSnapshot,
    argv: &[OsString],
    context: &EntryContext,
    config_store: &EntryConfigStore,
) -> Result<Option<i32>, CliError> {
    let Some(address) = argv.first() else {
        return Ok(None);
    };
    let address = address
        .to_str()
        .ok_or_else(|| CliError::new("command address is not valid Unicode"))?;
    let Some(command) = snapshot.commands.iter().find(|command| {
        command.address == address
            && command.adapter.as_deref() == Some("core")
            && (command.is_control() || command.handler.as_deref() == Some("entry.config.set"))
    }) else {
        return Ok(None);
    };
    if !command.runnable {
        let reason = command
            .diagnostic
            .as_deref()
            .unwrap_or("the command has no recognized Core entry");
        return Err(CliError::new(format!(
            "command '{address}' is not runnable: {reason}"
        )));
    }
    let arguments = argv.get(1..).unwrap_or_default();
    let exit_code = match command.handler.as_deref() {
        Some("entry.config") => show_config(arguments, config_store)?,
        Some("entry.config.set") => complete_core_command(
            core_config::set(address, arguments, config_store)
                .map_err(|error| CliError::new(error.to_string()))?,
        )?,
        Some("entry.config.apply") => apply_config(arguments, context, config_store)?,
        Some(handler) => {
            return Err(CliError::new(format!(
                "unsupported Core command handler: {handler}"
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

pub(super) fn resolve_control<'a>(
    snapshot: &'a CatalogSnapshot,
    address: &str,
) -> Result<&'a CommandNode, CliError> {
    let command = control_node(snapshot, address)?;
    if !command.runnable {
        let reason = command
            .diagnostic
            .as_deref()
            .unwrap_or("the command has no recognized Core entry");
        return Err(CliError::new(format!(
            "command '{address}' is not runnable: {reason}"
        )));
    }
    if command.adapter.as_deref() != Some("core") {
        return Err(CliError::new(format!(
            "Catalog invariant failed for '{address}': in-process System command is not a Core command"
        )));
    }
    Ok(command)
}

fn control_node<'a>(
    snapshot: &'a CatalogSnapshot,
    address: &str,
) -> Result<&'a CommandNode, CliError> {
    snapshot
        .commands
        .iter()
        .find(|node| node.is_control() && node.address == address)
        .ok_or_else(|| CliError::new(format!("command not found: {address}")))
}

fn show_runtime_status(arguments: &[OsString], context: &EntryContext) -> Result<i32, CliError> {
    let document = runtime_control::inspect(context).map_err(CliError::new)?;
    match arguments {
        [] => write_runtime_summary(&document)?,
        [format] if format == "--json" => {
            let output = serde_json::to_string_pretty(&document).map_err(|error| {
                CliError::new(format!("cannot serialize Runtime status: {error}"))
            })?;
            write_output(&output)
                .map_err(|error| CliError::new(format!("cannot write CLI output: {error}")))?;
        }
        _ => return Err(CliError::new("usage: .runtime [--json]")),
    }
    Ok(0)
}

fn request_host_action(
    address: &str,
    arguments: &[OsString],
    context: &EntryContext,
    action: HostAction,
) -> Result<i32, CliError> {
    require_no_arguments(address, arguments)?;
    runtime_control::request_host_action(context, action).map_err(CliError::new)?;
    let message = match action {
        HostAction::Exit => "Entry Host exit accepted.",
        HostAction::Restart => "Entry Host restart accepted.",
    };
    write_output(message)
        .map_err(|error| CliError::new(format!("cannot write CLI output: {error}")))?;
    Ok(0)
}

fn cleanup_runtime(
    address: &str,
    arguments: &[OsString],
    context: &EntryContext,
) -> Result<i32, CliError> {
    let apply = match arguments {
        [] => false,
        [argument] if argument == "--apply" => true,
        _ => return Err(CliError::new(format!("usage: {address} [--apply]"))),
    };
    runtime_cleanup::execute_text(context, apply).map_err(CliError::new)
}

fn show_config(arguments: &[OsString], config_store: &EntryConfigStore) -> Result<i32, CliError> {
    let document = config_store.document();
    match arguments {
        [] => write_config_summary(&document)?,
        [format] if format == "--json" => write_json(&document)?,
        _ => {
            return Err(CliError::new("usage: .entry [--json]"));
        }
    }
    Ok(0)
}

fn apply_config(
    arguments: &[OsString],
    context: &EntryContext,
    config_store: &EntryConfigStore,
) -> Result<i32, CliError> {
    let [option, path] = arguments else {
        return Err(CliError::new(
            "usage: .entry/apply --file <entry-config.json>",
        ));
    };
    if option != "--file" {
        return Err(CliError::new(
            "usage: .entry/apply --file <entry-config.json>",
        ));
    }
    let path = resolve_input_path(path, &context.invocation_directory);
    let document = config_store
        .replace_from_file(&path)
        .map_err(|error| CliError::new(error.to_string()))?;
    write_json(&document)?;
    Ok(0)
}

fn resolve_input_path(value: &OsString, invocation_directory: &Path) -> PathBuf {
    let path = PathBuf::from(value);
    if path.is_absolute() {
        path
    } else {
        invocation_directory.join(path)
    }
}

fn require_no_arguments(address: &str, arguments: &[OsString]) -> Result<(), CliError> {
    if arguments.is_empty() {
        Ok(())
    } else {
        Err(CliError::new(format!(
            "{address} does not accept arguments"
        )))
    }
}

fn write_config_summary(document: &EntryConfigDocument) -> Result<(), CliError> {
    let resolved = document
        .resolved_project_root
        .as_deref()
        .unwrap_or("not resolved");
    let mut output = format!(
        "Entry Config\nStatus: {}\nFile: {}\nProject: {}\nResolved: {}",
        document.status,
        document.path,
        document
            .config
            .project_root
            .as_deref()
            .unwrap_or("not configured"),
        resolved
    );
    if let Some(error) = &document.error {
        output.push_str("\nError: ");
        output.push_str(error);
    }
    write_output(&output)
        .map_err(|error| CliError::new(format!("cannot write CLI output: {error}")))
}

fn write_runtime_summary(document: &RuntimeStatusDocument) -> Result<(), CliError> {
    let mut output = format!(
        "Runtime\nSelected Release: {}\nReleases: {}",
        document.selected_release_id, document.release_count
    );
    match &document.host {
        Some(host) => {
            output.push_str(&format!(
                "\nHost: online\nPID: {}\nRunning Release: {}\nUpdate: {}",
                host.pid,
                host.running_release_id,
                if host.update_available {
                    "new Release pending restart"
                } else {
                    "current"
                }
            ));
        }
        None => output.push_str("\nHost: offline"),
    }
    write_output(&output)
        .map_err(|error| CliError::new(format!("cannot write CLI output: {error}")))
}

fn write_json(document: &EntryConfigDocument) -> Result<(), CliError> {
    let output = serde_json::to_string_pretty(document)
        .map_err(|error| CliError::new(format!("cannot serialize Entry Config: {error}")))?;
    write_output(&output)
        .map_err(|error| CliError::new(format!("cannot write CLI output: {error}")))
}
