#[cfg(not(target_os = "windows"))]
compile_error!("The Swaw Kit Proj application V0 supports Windows only.");

mod cli;
mod tray;

use std::error::Error;
use std::{env, path::PathBuf};

use swawkit_proj::{
    binding::ProjectBindingStore,
    context::EntryContext,
    data_root::{ClaimApprovalError, ResolveDataRootRequest, resolve_data_root},
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
            let inherited_data_root = env::var_os("SWAWKIT_PROJ_DATA_ROOT")
                .filter(|value| !value.is_empty())
                .map(PathBuf::from);
            let legacy_data_directory = env::var_os("SWAWKIT_PROJ_TARGET_PROJECT_ROOT")
                .filter(|value| !value.is_empty())
                .map(PathBuf::from)
                .map(|path| path.join("data"));
            let mut reject_claim = |claim: &swawkit_proj::data_root::DataRootClaim| {
                Err(ClaimApprovalError::new(format!(
                    "DataRoot '{}' requires interactive ownership confirmation; run the entry in a terminal first",
                    claim.data_root.display()
                )))
            };
            let resolved = resolve_data_root(
                ResolveDataRootRequest {
                    swawkit_home: &context.swawkit_home,
                    entry_file: &context.entry_file,
                    inherited_data_root: inherited_data_root.as_deref(),
                    legacy_data_directory: legacy_data_directory.as_deref(),
                },
                &mut reject_claim,
            )?;
            for warning in resolved.warnings {
                eprintln!("[WARNING] {warning}");
            }
            let binding_store = ProjectBindingStore::new(&context.swawkit_home, resolved.path);
            tray::run(context, binding_store)?;
            Ok(0)
        }
    }
}
