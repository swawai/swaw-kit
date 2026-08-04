mod claim;

use std::env;
use std::error::Error;
use std::ffi::OsString;
use std::fmt;
use std::io::{self, Write};
use std::path::PathBuf;

use swawkit_proj::{
    catalog::{CatalogSnapshot, is_help_marker},
    command::{CommandExecutionContext, CommandExecutor},
    context::EntryContext,
    data_root::{
        DataRootClaimApprover, ResolveDataRootRequest, resolve_data_root,
    },
    help::{HelpRenderError, render_help},
};

use claim::ConsoleClaimApprover;

pub fn run(context: &EntryContext, argv: &[OsString]) -> Result<i32, CliError> {
    let mut approver = ConsoleClaimApprover::default();
    let inherited_data_root = env::var_os("SWAWKIT_PROJ_DATA_ROOT")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from);
    run_with_approver(
        context,
        argv,
        inherited_data_root.as_deref(),
        &mut approver,
    )
}

fn run_with_approver(
    context: &EntryContext,
    argv: &[OsString],
    inherited_data_root: Option<&std::path::Path>,
    approver: &mut impl DataRootClaimApprover,
) -> Result<i32, CliError> {
    let snapshot = CatalogSnapshot::discover(context)
        .map_err(|error| CliError::new(format!("catalog discovery failed: {error}")))?;
    if let Some(output) = protocol_help(&snapshot, argv)? {
        write_output(&output)
            .map_err(|error| CliError::new(format!("cannot write CLI output: {error}")))?;
        return Ok(0);
    }
    CommandExecutor::preflight(&context.kernel_root(), &snapshot, argv)
        .map_err(|error| CliError::new(error.to_string()))?;

    let resolved = resolve_data_root(
        ResolveDataRootRequest {
            proj_home: &context.proj_home,
            project_root: &context.project_root,
            action_root: &context.action_root,
            entry_file: &context.entry_file,
            inherited_data_root,
        },
        approver,
    )
    .map_err(|error| CliError::new(format!("DataRoot resolution failed: {error}")))?;
    for warning in resolved.warnings {
        eprintln!("[WARNING] {warning}");
    }

    let execution_context = CommandExecutionContext::new(context, resolved.path);
    CommandExecutor::new(&execution_context, &snapshot)
        .execute(argv)
        .map_err(|error| CliError::new(error.to_string()))
}

fn protocol_help(
    snapshot: &CatalogSnapshot,
    argv: &[OsString],
) -> Result<Option<String>, CliError> {
    let Some(target) = help_target(argv)? else {
        return Ok(None);
    };
    match render_help(snapshot, &target) {
        Ok(output) => Ok(Some(output)),
        Err(HelpRenderError::Unavailable(address)) if !address.is_empty() => Ok(None),
        Err(error) => Err(CliError::new(error.to_string())),
    }
}

fn help_target(argv: &[OsString]) -> Result<Option<String>, CliError> {
    match argv {
        [marker] if marker.to_str().is_some_and(is_help_marker) => Ok(Some(String::new())),
        [target, marker] if marker.to_str().is_some_and(is_help_marker) => {
            let target = target.to_str().ok_or_else(|| {
                CliError::new("help target address is not valid Unicode")
            })?;
            Ok(Some(target.to_owned()))
        }
        _ => Ok(None),
    }
}

fn write_output(output: &str) -> io::Result<()> {
    let stdout = io::stdout();
    let mut handle = stdout.lock();
    handle.write_all(output.as_bytes())?;
    handle.write_all(b"\n")?;
    handle.flush()
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CliError {
    message: String,
}

impl CliError {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl fmt::Display for CliError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl Error for CliError {}

#[cfg(test)]
mod tests;
