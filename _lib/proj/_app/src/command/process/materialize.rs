use std::ffi::{OsStr, OsString};
use std::path::Path;
use std::process::Command;

use crate::catalog::CommandAdapter;
use crate::command::{CommandError, CommandResult, ProcessEnvironment};
use crate::process_environment::environment_value;

use super::{AdapterLaunch, adapter_command, validate_command_processor};

/// Materializes an isolated child command for the common ProcessRunner.
///
/// This must be called close to spawn. The baseline is one current-user
/// snapshot; it is also the sole source of `ComSpec` for a Cmd adapter.
pub(in crate::command) fn materialize_isolated_command(
    adapter: CommandAdapter,
    entry_path: &Path,
    arguments: &[OsString],
    working_directory: &Path,
    adapter_launch: &AdapterLaunch,
    environment: &ProcessEnvironment,
    baseline: &[(OsString, OsString)],
) -> CommandResult<Command> {
    let cmd_executable = if adapter == CommandAdapter::Cmd {
        Some(command_processor_from_environment(baseline)?)
    } else {
        None
    };
    let mut command = adapter_command(
        adapter,
        entry_path,
        arguments,
        adapter_launch,
        cmd_executable.as_deref(),
    )?;
    let adapter_environment = command
        .get_envs()
        .map(|(name, value)| (name.to_owned(), value.map(OsStr::to_owned)))
        .collect::<Vec<_>>();
    command
        .current_dir(working_directory)
        .env_clear()
        .envs(baseline.iter().cloned());
    for (name, value) in adapter_environment {
        match value {
            Some(value) => {
                command.env(name, value);
            }
            None => {
                command.env_remove(name);
            }
        }
    }
    environment.apply(&mut command);
    Ok(command)
}

fn command_processor_from_environment(
    environment: &[(OsString, OsString)],
) -> CommandResult<std::path::PathBuf> {
    let executable = environment_value(environment, "ComSpec")
        .filter(|value| !value.is_empty())
        .ok_or_else(|| CommandError::new("the Windows command processor is unavailable"))?;
    validate_command_processor(Path::new(executable))
}
