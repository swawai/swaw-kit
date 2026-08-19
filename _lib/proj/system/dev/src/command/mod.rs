mod context;
mod setup;
mod status;

use std::ffi::OsString;

use context::CommandContext;

pub(crate) fn run(address: &str, arguments: &[OsString]) -> Result<(), String> {
    let context = CommandContext::from_environment(address)?;
    match address {
        ".dev/setup" => setup::run(&context, arguments),
        ".dev/status" => status::run(&context, arguments),
        _ => Err(format!("unsupported Dev command address '{address}'")),
    }
}
