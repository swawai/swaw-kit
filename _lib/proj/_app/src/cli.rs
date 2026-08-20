mod control;
mod entry_manager;

use std::error::Error;
use std::ffi::OsString;
use std::fmt;
use std::io::{self, Write};

use swawkit_proj::{
    catalog::CatalogSnapshot,
    command::{CommandExecutionContext, CommandExecutor, CommandProcessMode, ConsoleCancellation},
    context::EntryContext,
    core_command::{CoreCommandOutcome, check as core_check, help as core_help, runs as core_runs},
    data_root::{ResolveDataRootRequest, ResolvedDataRoot, resolve_data_root},
    profile::{EntryProfileState, EntryProfileStore},
};

pub fn run_cancelable(
    context: &EntryContext,
    argv: &[OsString],
    process_mode: CommandProcessMode,
    cancellation: &ConsoleCancellation,
) -> Result<i32, CliError> {
    run_with_cancellation(context, argv, process_mode, Some(cancellation))
}

fn run_with_cancellation(
    context: &EntryContext,
    argv: &[OsString],
    process_mode: CommandProcessMode,
    cancellation: Option<&ConsoleCancellation>,
) -> Result<i32, CliError> {
    run_with_dependencies(context, argv, process_mode, cancellation)
}

fn run_with_dependencies(
    context: &EntryContext,
    argv: &[OsString],
    process_mode: CommandProcessMode,
    cancellation: Option<&ConsoleCancellation>,
) -> Result<i32, CliError> {
    if let Some(exit_code) = control::dispatch_help_before_data_root(context, argv)? {
        return Ok(exit_code);
    }

    if core_check::is_invocation(argv) {
        return run_read_only_check(context, argv);
    }

    let resolved = resolve_owned_data_root(context)?;

    if let Some(exit_code) = control::dispatch_runtime(context, argv, &resolved)? {
        return Ok(exit_code);
    }
    if let Some(exit_code) = entry_manager::dispatch(context, argv)? {
        return Ok(exit_code);
    }

    let profile_store = EntryProfileStore::new(&context.swawkit_home, resolved.path());
    let profile_state = profile_store.read();
    let snapshot = CatalogSnapshot::discover(context, profile_state.ready())
        .map_err(|error| CliError::new(format!("catalog discovery failed: {error}")))?;
    if let Some(outcome) =
        core_help::execute(&snapshot, argv).map_err(|error| CliError::new(error.to_string()))?
    {
        return complete_core_command(outcome);
    }
    if let Some(outcome) =
        core_runs::execute(&snapshot, argv, context, resolved.path(), &profile_state)
            .map_err(|error| CliError::new(error.to_string()))?
    {
        return complete_core_command(outcome);
    }
    if let Some(exit_code) = control::dispatch(&snapshot, argv, context, &profile_store)? {
        return Ok(exit_code);
    }
    CommandExecutor::validate_invocation(&snapshot, argv)
        .map_err(|error| CliError::new(error.to_string()))?;
    let profile = match profile_state {
        EntryProfileState::Ready(profile) => profile,
        EntryProfileState::Missing { path } => {
            return Err(CliError::new(format!(
                "this entry has no profile: {}. Run '{} .entry' or launch '{}' without arguments to complete initial setup",
                path.display(),
                context.entry_name,
                context.entry_name,
            )));
        }
        EntryProfileState::Invalid { path, error, .. } => {
            return Err(CliError::new(format!(
                "invalid entry profile '{}': {error}",
                path.display()
            )));
        }
    };
    let execution_context =
        CommandExecutionContext::new(context, &profile, resolved.path(), process_mode)
            .map_err(|error| CliError::new(error.to_string()))?;
    let executor = CommandExecutor::new(&execution_context, &snapshot);
    match process_mode {
        CommandProcessMode::InheritConsole => match cancellation {
            Some(cancellation) => executor.execute_journaled_cancelable(argv, cancellation),
            None => executor.execute_journaled(argv),
        },
        CommandProcessMode::NoWindow => executor.execute(argv),
    }
    .map_err(|error| CliError::new(error.to_string()))
}

fn run_read_only_check(context: &EntryContext, argv: &[OsString]) -> Result<i32, CliError> {
    let resolved = resolve_owned_data_root(context)?;

    let profile_state = EntryProfileStore::new(&context.swawkit_home, resolved.path()).read();
    let snapshot = CatalogSnapshot::discover(context, profile_state.ready())
        .map_err(|error| CliError::new(format!("catalog discovery failed: {error}")))?;
    let outcome = core_check::execute(&snapshot, argv, context, resolved.path())
        .map_err(|error| CliError::new(error.to_string()))?
        .ok_or_else(|| CliError::new("Catalog invariant failed: .check was not dispatched"))?;
    complete_core_command(outcome)
}

fn resolve_owned_data_root(context: &EntryContext) -> Result<ResolvedDataRoot, CliError> {
    let resolved = resolve_data_root(ResolveDataRootRequest {
        swawkit_home: &context.swawkit_home,
        entry_file: &context.entry_file,
    })
    .map_err(|error| CliError::new(format!("DataRoot resolution failed: {error}")))?;
    if resolved.path() != context.data_root {
        return Err(CliError::new(format!(
            "resolved DataRoot does not match the running Runtime: expected '{}', received '{}'",
            context.data_root.display(),
            resolved.path().display()
        )));
    }
    Ok(resolved)
}

fn complete_core_command(outcome: CoreCommandOutcome) -> Result<i32, CliError> {
    write_raw_output(&outcome.stdout)
        .map_err(|error| CliError::new(format!("cannot write CLI output: {error}")))?;
    Ok(outcome.exit_code)
}

fn write_output(output: &str) -> io::Result<()> {
    write_raw_output(&format!("{output}\n"))
}

fn write_raw_output(output: &str) -> io::Result<()> {
    let stdout = io::stdout();
    let mut handle = stdout.lock();
    handle.write_all(output.as_bytes())?;
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
