use std::env;
use std::ffi::{OsStr, OsString};
use std::os::windows::process::CommandExt;
use std::path::Path;
use std::process::Command;

use crate::catalog::{CommandAdapter, is_help_marker};

use super::{CommandError, CommandResult, ProcessEnvironment};

const POWERSHELL_ARGUMENT_PREFIX: &str = "SWAWKIT_INTERNAL_PS_ARG_";
const POWERSHELL_ENTRY_ENV: &str = "SWAWKIT_INTERNAL_PS_ENTRY_PATH";
const POWERSHELL_COUNT_ENV: &str = "SWAWKIT_INTERNAL_PS_ARGC";
const CMD_ENTRY_ENV: &str = "SWAWKIT_INTERNAL_CMD_ENTRY_PATH";

const POWERSHELL_RUNNER: &str = r#"
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
try {
    $entryPath = [Environment]::GetEnvironmentVariable('SWAWKIT_INTERNAL_PS_ENTRY_PATH', 'Process')
    $countText = [Environment]::GetEnvironmentVariable('SWAWKIT_INTERNAL_PS_ARGC', 'Process')
    $count = [int]::Parse($countText, [Globalization.CultureInfo]::InvariantCulture)
    [string[]]$entryArguments = @()
    for ($index = 0; $index -lt $count; $index++) {
        $entryArguments += [Environment]::GetEnvironmentVariable(
            ('SWAWKIT_INTERNAL_PS_ARG_' + $index),
            'Process'
        )
    }
    $global:LASTEXITCODE = 0
    & $entryPath @entryArguments
    $entrySucceeded = $?
    $entryExitCode = [int]$global:LASTEXITCODE
    if (-not $entrySucceeded -and $entryExitCode -eq 0) {
        $entryExitCode = 1
    }
    exit $entryExitCode
} catch {
    [Console]::Error.WriteLine(
        ('PowerShell entry failed: entry={0}; data={1}; error={2}; at={3}' -f
            $entryPath,
            $env:SWAWKIT_PROJ_DATA_ROOT,
            $_.Exception.Message,
            $_.InvocationInfo.PositionMessage)
    )
    exit 1
}
"#;

pub(crate) fn run_process(
    adapter: CommandAdapter,
    entry_path: &Path,
    arguments: &[OsString],
    working_directory: &Path,
    environment: &ProcessEnvironment,
) -> CommandResult<i32> {
    validate_adapter(adapter)?;
    let mut command = match adapter {
        CommandAdapter::Exe => executable_command(entry_path, arguments),
        CommandAdapter::PowerShell => powershell_command(entry_path, arguments)?,
        CommandAdapter::Cmd => cmd_command(entry_path, arguments)?,
        CommandAdapter::Bun | CommandAdapter::Python => unreachable!(),
    };
    command.current_dir(working_directory);
    environment.apply(&mut command);
    let status = command.status().map_err(|error| {
        CommandError::new(format!(
            "cannot start command entry '{}': {error}",
            entry_path.display()
        ))
    })?;
    Ok(status.code().unwrap_or(1))
}

pub(crate) fn validate_adapter(adapter: CommandAdapter) -> CommandResult<()> {
    if matches!(
        adapter,
        CommandAdapter::Exe | CommandAdapter::PowerShell | CommandAdapter::Cmd
    ) {
        return Ok(());
    }
    Err(CommandError::new(format!(
        "the Rust V0 executor does not yet support the '{}' adapter",
        adapter.as_str()
    )))
}

fn executable_command(entry_path: &Path, arguments: &[OsString]) -> Command {
    let mut command = Command::new(entry_path);
    command.args(arguments);
    command
}

fn powershell_command(entry_path: &Path, arguments: &[OsString]) -> CommandResult<Command> {
    let system_root = env::var_os("SystemRoot")
        .filter(|value| !value.is_empty())
        .ok_or_else(|| CommandError::new("SystemRoot is unavailable"))?;
    let executable = Path::new(&system_root)
        .join("System32")
        .join("WindowsPowerShell")
        .join("v1.0")
        .join("powershell.exe");
    if !executable.is_file() {
        return Err(CommandError::new(format!(
            "Windows PowerShell is unavailable: {}",
            executable.display()
        )));
    }

    let mut command = Command::new(executable);
    command.args([
        OsStr::new("-NoLogo"),
        OsStr::new("-NoProfile"),
        OsStr::new("-ExecutionPolicy"),
        OsStr::new("Bypass"),
        OsStr::new("-Command"),
        OsStr::new(POWERSHELL_RUNNER),
    ]);
    command.env(POWERSHELL_ENTRY_ENV, entry_path);
    command.env(POWERSHELL_COUNT_ENV, arguments.len().to_string());
    for (index, argument) in arguments.iter().enumerate() {
        command.env(format!("{POWERSHELL_ARGUMENT_PREFIX}{index}"), argument);
    }
    Ok(command)
}

fn cmd_command(entry_path: &Path, arguments: &[OsString]) -> CommandResult<Command> {
    let marker = match arguments {
        [] => None,
        [marker] if marker.to_str().is_some_and(is_help_marker) => marker.to_str(),
        _ => {
            return Err(CommandError::new(
                "the V0 run.cmd adapter accepts no dynamic arguments except one standalone help \
                 selector",
            ));
        }
    };
    let executable = env::var_os("ComSpec")
        .filter(|value| !value.is_empty())
        .ok_or_else(|| CommandError::new("the Windows command processor is unavailable"))?;
    if !Path::new(&executable).is_file() {
        return Err(CommandError::new(format!(
            "the Windows command processor is unavailable: {}",
            Path::new(&executable).display()
        )));
    }

    let command_line = match marker {
        Some(marker) => format!("/d /s /v:off /c \"\"%{CMD_ENTRY_ENV}%\" {marker}\""),
        None => format!("/d /s /v:off /c \"\"%{CMD_ENTRY_ENV}%\"\""),
    };
    let mut command = Command::new(executable);
    command.raw_arg(command_line);
    command.env(CMD_ENTRY_ENV, entry_path);
    Ok(command)
}
