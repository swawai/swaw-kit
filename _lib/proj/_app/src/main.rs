#[cfg(not(target_os = "windows"))]
compile_error!("The Swaw Kit Proj application V0 supports Windows only.");

mod cli;
mod tray;

use std::error::Error;

use swawkit_proj::{
    context::EntryContext,
    launch::{LaunchMode, LaunchRequest},
};

fn main() {
    match run() {
        Ok(0) => {}
        Ok(exit_code) => std::process::exit(exit_code),
        Err(error) => {
            eprintln!("[ERROR] {error}");
            std::process::exit(1);
        }
    }
}

fn run() -> Result<i32, Box<dyn Error>> {
    let request = LaunchRequest::from_process()?;
    let context = EntryContext::from_launch(&request)?;

    match request.mode {
        LaunchMode::Cli => cli::run(&context, &request.argv).map_err(Into::into),
        LaunchMode::InternalHost => {
            tray::run(context)?;
            Ok(0)
        }
    }
}
