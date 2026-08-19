#![cfg_attr(not(test), windows_subsystem = "console")]

#[cfg(not(windows))]
compile_error!("The Swaw Kit Module manager supports Windows only.");

mod builder_environment;
mod filesystem;
mod instantiate;
mod manifest;
mod release_store;
mod snapshot;
mod status;
mod transport;

use std::process::ExitCode;

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("swawkit-proj-module: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), String> {
    let invocation = transport::Invocation::from_process()?;
    match invocation.address.as_str() {
        ".module/instantiate" => instantiate::run(&invocation.context, &invocation.arguments),
        ".module/status" => status::run(&invocation.context, &invocation.arguments),
        _ => Err(format!(
            "unsupported Module manager command '{}'",
            invocation.address
        )),
    }
}
