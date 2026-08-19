#![cfg_attr(not(test), windows_subsystem = "console")]

#[cfg(not(windows))]
compile_error!("The Swaw Kit Proj Dev runtime currently supports Windows only.");

mod command;
mod event;

use std::ffi::OsString;
use std::process::ExitCode;

fn main() -> ExitCode {
    match run(std::env::args_os().skip(1).collect()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("swawkit-proj-dev: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run(arguments: Vec<OsString>) -> Result<(), String> {
    let mut arguments = arguments.into_iter();
    let protocol = arguments
        .next()
        .and_then(|value| value.into_string().ok())
        .ok_or_else(usage)?;
    if protocol != "command-v1" {
        return Err(usage());
    }
    let address = arguments
        .next()
        .and_then(|value| value.into_string().ok())
        .ok_or_else(usage)?;
    command::run(&address, &arguments.collect::<Vec<_>>())
}

fn usage() -> String {
    "expected: swawkit-proj-dev.exe command-v1 <command-address> [arguments...]".to_owned()
}
