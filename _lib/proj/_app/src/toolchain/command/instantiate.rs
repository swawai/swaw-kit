use std::ffi::OsString;

use swawkit_proj::catalog::CatalogSnapshot;
use swawkit_proj::native_command;

use super::CommandContext;

pub(super) fn run(context: &CommandContext, arguments: &[OsString]) -> Result<(), String> {
    let [address] = arguments else {
        return Err(".module/instantiate requires exactly one command address".to_owned());
    };
    let address = address
        .to_str()
        .ok_or_else(|| "module command address must be valid Unicode".to_owned())?;
    if address.is_empty() {
        return Err("module command address cannot be empty".to_owned());
    }

    let system_root = context.swawkit_home.join("_lib/proj/system");
    let catalog = CatalogSnapshot::discover_mounted_roots(
        &system_root,
        &context.module_roots,
        &context.entry_command,
    )
    .map_err(|error| format!("cannot discover the command Catalog: {error}"))?;
    let mut matches = catalog
        .commands
        .iter()
        .filter(|command| command.address == address);
    let command = matches
        .next()
        .ok_or_else(|| format!("command not found: {address}"))?;
    if matches.next().is_some() {
        return Err(format!("ambiguous command address: {address}"));
    }
    let publication = native_command::instantiate(&context.data_root, &catalog, command)?;
    let action = if publication.changed {
        "published"
    } else {
        "already current"
    };
    println!(
        "Native module target {}: {action} {}",
        native_command::instantiation_target_address(command)?,
        publication.release_id,
    );
    Ok(())
}
