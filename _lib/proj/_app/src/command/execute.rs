use std::ffi::OsString;
use std::path::Path;

use crate::catalog::{CatalogSnapshot, CommandAdapter, CommandSpace};
use crate::native_command;
use crate::run_journal::{RunJournal, RunJournalPhase, RunJournalSource, StartRunJournal};

use super::{
    CommandError, CommandExecutionContext, CommandResult, ConsoleCancellation, Invocation,
    ProcessEnvironment, ResolvedCommand, command_data_root,
    process::{AdapterLaunch, run_process, run_process_journaled, validate_adapter},
    resolve_entry_development,
};

pub struct CommandExecutor<'a> {
    context: &'a CommandExecutionContext,
    catalog: &'a CatalogSnapshot,
}

impl<'a> CommandExecutor<'a> {
    pub fn new(context: &'a CommandExecutionContext, catalog: &'a CatalogSnapshot) -> Self {
        Self { context, catalog }
    }

    pub fn validate_invocation(catalog: &CatalogSnapshot, argv: &[OsString]) -> CommandResult<()> {
        let invocation = Invocation::resolve(catalog, argv)?;
        validate_command_adapter(&invocation.command)?;
        Ok(())
    }

    pub fn execute(&self, argv: &[OsString]) -> CommandResult<i32> {
        let invocation = Invocation::resolve(self.catalog, argv)?;
        self.assert_dependencies_ready(&invocation)?;
        self.execute_invocation(&invocation, None)
    }

    pub fn execute_journaled(&self, argv: &[OsString]) -> CommandResult<i32> {
        self.execute_journaled_with_cancellation(argv, None)
    }

    pub fn execute_journaled_cancelable(
        &self,
        argv: &[OsString],
        cancellation: &ConsoleCancellation,
    ) -> CommandResult<i32> {
        self.execute_journaled_with_cancellation(argv, Some(cancellation))
    }

    fn execute_journaled_with_cancellation(
        &self,
        argv: &[OsString],
        cancellation: Option<&ConsoleCancellation>,
    ) -> CommandResult<i32> {
        let invocation = Invocation::resolve(self.catalog, argv)?;
        self.assert_dependencies_ready(&invocation)?;
        if invocation.command.handler.as_deref() == Some("dev.setup") {
            crate::development::setup::provider::migrate_legacy_layout(&self.context.data_root)
                .map_err(CommandError::new)?;
        }
        let journal = RunJournal::start(StartRunJournal {
            module_data_root: command_data_root(self.context, &invocation.command)?,
            address: invocation.command.address.clone(),
            source: RunJournalSource::Cli,
            argument_count: invocation.arguments.len(),
            profile_revision: self.context.profile_revision.clone(),
        })
        .map_err(|error| CommandError::new(format!("cannot start command journal: {error}")))?;
        let result = self.execute_invocation(&invocation, Some(&journal));
        if cancellation.is_some_and(|cancellation| {
            cancellation.requested() && !cancellation.termination_failed()
        }) {
            return journal.finish_canceled().map(|()| 130).map_err(|error| {
                CommandError::new(format!("cannot cancel command journal: {error}"))
            });
        }
        match result {
            Ok(exit_code) => journal
                .finish_exited(exit_code)
                .map(|()| exit_code)
                .map_err(|error| {
                    CommandError::new(format!("cannot complete command journal: {error}"))
                }),
            Err(error) => {
                let journal_result = journal.finish_failed(error.to_string());
                match journal_result {
                    Ok(()) => Err(error),
                    Err(journal_error) => Err(CommandError::new(format!(
                        "{error}; additionally, command journal completion failed: {journal_error}"
                    ))),
                }
            }
        }
    }

    fn assert_dependencies_ready(&self, invocation: &Invocation) -> CommandResult<()> {
        crate::command_check::assert_dependencies_ready(
            &self.context.data_root,
            &self.context.entry_name,
            self.catalog,
            &invocation.command.address,
        )
        .map_err(CommandError::new)
    }

    fn execute_invocation(
        &self,
        invocation: &Invocation,
        journal: Option<&RunJournal>,
    ) -> CommandResult<i32> {
        validate_command_adapter(&invocation.command)?;
        let mut development_environment = None;
        let mut native_resolution = None;
        let adapter_launch = match invocation.command.adapter {
            CommandAdapter::Bun => {
                let resolved = resolve_entry_development(self.context)?;
                development_environment = Some(resolved.environment);
                AdapterLaunch::Bun(resolved.bun_executable.ok_or_else(|| {
                    CommandError::new(format!(
                        "Bun is disabled for this Entry. Run '{} .dev/bun/mode managed', then '{} .dev/setup'",
                        self.context.entry_name, self.context.entry_name
                    ))
                })?)
            }
            CommandAdapter::Pwsh => {
                let resolved = resolve_entry_development(self.context)?;
                development_environment = Some(resolved.environment);
                AdapterLaunch::Pwsh(resolved.pwsh_executable.ok_or_else(|| {
                    CommandError::new(format!(
                        "PowerShell 7 is disabled for this Entry. Run '{} .dev/pwsh/mode managed', then '{} .dev/setup'",
                        self.context.entry_name, self.context.entry_name
                    ))
                })?)
            }
            CommandAdapter::Toolchain => {
                let handler = invocation.command.handler.clone().ok_or_else(|| {
                    CommandError::new("Catalog invariant failed: Toolchain command has no handler")
                })?;
                if handler == "module.instantiate" {
                    development_environment =
                        Some(resolve_entry_development(self.context)?.environment);
                }
                AdapterLaunch::Toolchain {
                    executable: self.context.toolchain_executable.clone(),
                    handler,
                }
            }
            CommandAdapter::Native | CommandAdapter::Delegate => {
                let instantiate_target = native_command::instantiation_target(&invocation.command)?;
                let resolution = native_command::resolve_command_executable(
                    self.context,
                    self.catalog,
                    &invocation.command,
                )
                .map_err(|error| {
                    CommandError::new(format!(
                        "{error}; run '{} .module/instantiate {}'",
                        self.context.entry_name, instantiate_target
                    ))
                })?;
                let executable = resolution.executable.clone();
                native_resolution = Some(resolution);
                AdapterLaunch::Native(executable)
            }
            _ => AdapterLaunch::Direct,
        };
        let mut environment = ProcessEnvironment::for_command(self.context, &invocation.command)?;
        if let Some(plan) = &development_environment {
            environment.apply_development_environment(
                plan,
                &self
                    .context
                    .data_root
                    .join("modules/system/dev/setup/export"),
            )?;
        }
        if let Some(resolution) = &native_resolution {
            environment.apply_native_owner(
                &resolution.owner_address,
                &resolution.owner_directory,
                &resolution.owner_data_root,
            );
        }
        run(
            invocation.command.adapter,
            &invocation.command.entry_path,
            &invocation.arguments,
            &self.context.target_project_root,
            &adapter_launch,
            &environment,
            self.context.process_mode,
            journal,
        )
    }
}

#[allow(clippy::too_many_arguments)]
fn run(
    adapter: crate::catalog::CommandAdapter,
    entry_path: &Path,
    arguments: &[OsString],
    working_directory: &Path,
    adapter_launch: &AdapterLaunch,
    environment: &ProcessEnvironment,
    process_mode: super::CommandProcessMode,
    journal: Option<&RunJournal>,
) -> CommandResult<i32> {
    match journal {
        Some(journal) => run_process_journaled(
            adapter,
            entry_path,
            arguments,
            working_directory,
            adapter_launch,
            environment,
            process_mode,
            journal,
            RunJournalPhase::Run,
        ),
        None => run_process(
            adapter,
            entry_path,
            arguments,
            working_directory,
            adapter_launch,
            environment,
            process_mode,
        ),
    }
}

fn validate_command_adapter(command: &ResolvedCommand) -> CommandResult<()> {
    validate_adapter(command.adapter)?;
    if command.adapter == CommandAdapter::Toolchain && command.handler.is_none() {
        return Err(CommandError::new(
            "Catalog invariant failed: Toolchain command has no handler",
        ));
    }
    if command.adapter == CommandAdapter::Bun && command.space != CommandSpace::Module {
        return Err(CommandError::new(format!(
            "the run.ts adapter is only supported for Module commands; '{}' is a System command",
            command.address
        )));
    }
    if command.adapter == CommandAdapter::Toolchain && command.space != CommandSpace::System {
        return Err(CommandError::new(format!(
            "toolchain execution is only supported for System commands; '{}' has an invalid owner",
            command.address
        )));
    }
    if matches!(
        command.adapter,
        CommandAdapter::Native | CommandAdapter::Delegate
    ) && command.space == CommandSpace::System
    {
        return Err(CommandError::new(format!(
            "native command entries are not supported for System command '{}'",
            command.address
        )));
    }
    Ok(())
}
