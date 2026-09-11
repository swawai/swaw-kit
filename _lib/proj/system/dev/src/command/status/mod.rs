use std::ffi::OsString;

use super::context::CommandContext;
use swawkit_proj_dev::development::setup::declaration::snapshot_from_settings;

mod archive_tool;
mod filesystem;
mod msvc;
mod provider;
mod rust;

pub(super) fn run(context: &CommandContext, arguments: &[OsString]) -> Result<(), String> {
    if !arguments.is_empty() {
        return Err(".dev/status does not accept dynamic arguments".to_owned());
    }

    let declarations = snapshot_from_settings(context.settings.settings());
    match provider::publication_token(context) {
        Ok(token) => println!("[READY] .dev/setup publication {}", &token[..8]),
        Err(error) => println!("[OUTDATED] {error}"),
    }
    let bun = archive_tool::inspect(context, &declarations, &swawkit_proj_dev::development::BUN)?;
    bun.render(&swawkit_proj_dev::development::BUN);
    let pwsh = archive_tool::inspect(context, &declarations, &swawkit_proj_dev::development::PWSH)?;
    pwsh.render(&swawkit_proj_dev::development::PWSH);
    msvc::inspect(context, &declarations)?.render();
    rust::inspect(context, &declarations)?.render();
    Ok(())
}
