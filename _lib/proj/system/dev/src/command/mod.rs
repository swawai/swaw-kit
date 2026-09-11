mod check;
mod context;
mod settings;
mod setup;
mod status;

use std::ffi::OsString;

use context::CommandContext;

pub(crate) fn run(address: &str, arguments: &[OsString]) -> Result<u8, String> {
    let context = CommandContext::from_environment(address)?;
    match address {
        ".dev/settings" => settings::show(&context, arguments),
        ".dev/setup" => setup::run(&context, arguments).map(|()| 0),
        ".dev/setup/check" => check::run(&context, arguments),
        ".dev/status" => status::run(&context, arguments).map(|()| 0),
        address if swawkit_proj_dev::development::setup::settings::is_setting_address(address) => {
            settings::set(&context, address, arguments)
        }
        _ => Err(format!("unsupported Dev command address '{address}'")),
    }
}
