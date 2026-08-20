use std::ffi::OsString;

use crate::catalog::{CatalogSnapshot, CommandAdapter, CommandSpace};
use crate::command_runtime::CommandRuntime;
use crate::native_command;
use crate::run_journal::{RunJournal, RunJournalSource, StartRunJournal};

use super::{
    CommandError, CommandExecutionContext, CommandResult, ConsoleCancellation, Invocation,
    PlannedCommand, PreparedCommand, ProcessEnvironment, ResolvedCommand, command_data_root,
    process::{AdapterLaunch, validate_adapter},
    validate_dev_executable, validate_module_executable,
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
        self.prepare(argv)?.execute()
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
        let plan = self.plan(argv)?;
        let journal = RunJournal::start(StartRunJournal {
            module_data_root: command_data_root(self.context, plan.command())?,
            address: plan.command().address.clone(),
            source: RunJournalSource::Cli,
            argument_count: plan.argument_count(),
            profile_revision: self.context.profile_revision.clone(),
        })
        .map_err(|error| CommandError::new(format!("cannot start command journal: {error}")))?;
        // Keep the existing side-effect boundary: adapter/runtime/native and
        // ProcessEnvironment preparation happens after the Journal starts, so
        // a preparation failure is still persisted as a failed CLI run.
        let result = self
            .materialize(plan)
            .and_then(|prepared| prepared.execute_journaled(&journal));
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

    pub(crate) fn prepare(&self, argv: &[OsString]) -> CommandResult<PreparedCommand> {
        let plan = self.plan(argv)?;
        self.materialize(plan)
    }

    /// Resolves only the logical invocation and its declared dependencies.
    /// Adapter artifacts, command environment, and OS launch state are
    /// intentionally deferred until after a Run Journal has started.
    pub(crate) fn plan(&self, argv: &[OsString]) -> CommandResult<PlannedCommand> {
        let invocation = Invocation::resolve(self.catalog, argv)?;
        self.assert_dependencies_ready(&invocation)?;
        Ok(PlannedCommand::new(invocation))
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

    /// Materializes adapter/runtime/native state for an already checked plan.
    pub(crate) fn materialize(&self, plan: PlannedCommand) -> CommandResult<PreparedCommand> {
        let invocation = plan.into_invocation();
        validate_command_adapter(&invocation.command)?;
        let mut native_resolution = None;
        let adapter_launch = match invocation.command.adapter {
            CommandAdapter::Bun => AdapterLaunch::Bun(self.command_runtime_tool("bun")?),
            CommandAdapter::Pwsh => AdapterLaunch::Pwsh(self.command_runtime_tool("pwsh")?),
            CommandAdapter::Runtime => {
                let product = invocation.command.product.as_deref().ok_or_else(|| {
                    CommandError::new(
                        "Catalog invariant failed: Runtime Component command has no product",
                    )
                })?;
                let executable = match product {
                    "module" => {
                        validate_module_executable(&self.context.module_executable)?;
                        self.context.module_executable.clone()
                    }
                    "dev" => {
                        validate_dev_executable(&self.context.dev_executable)?;
                        self.context.dev_executable.clone()
                    }
                    _ => {
                        return Err(CommandError::new(format!(
                            "unsupported Runtime Component product '{product}'"
                        )));
                    }
                };
                AdapterLaunch::Runtime {
                    executable,
                    address: invocation.command.address.clone(),
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
        if let Some(resolution) = &native_resolution {
            environment.apply_native_owner(
                &resolution.owner_address,
                &resolution.owner_directory,
                &resolution.owner_data_root,
            );
        }
        Ok(PreparedCommand::new(
            invocation.command.adapter,
            invocation.command.entry_path,
            invocation.arguments,
            self.context.target_project_root.clone(),
            adapter_launch,
            environment,
            self.context.process_mode,
        ))
    }

    fn command_runtime_tool(&self, name: &str) -> CommandResult<std::path::PathBuf> {
        let runtime =
            CommandRuntime::open(&self.context.swawkit_home, &self.context.command_runtime_id)
                .map_err(|error| {
                    CommandError::new(format!("Command Runtime is invalid: {error}"))
                })?;
        runtime
            .tool(&self.context.swawkit_home, name)
            .map_err(|error| CommandError::new(format!("Command Runtime tool is invalid: {error}")))
    }
}

fn validate_command_adapter(command: &ResolvedCommand) -> CommandResult<()> {
    validate_adapter(command.adapter)?;
    if command.adapter == CommandAdapter::Runtime && command.product.is_none() {
        return Err(CommandError::new(
            "Catalog invariant failed: Runtime Component command has no product",
        ));
    }
    if command.adapter != CommandAdapter::Runtime && command.product.is_some() {
        return Err(CommandError::new(format!(
            "Catalog invariant failed: non-Runtime command '{}' declares a product",
            command.address
        )));
    }
    if command.adapter == CommandAdapter::Bun && command.space != CommandSpace::Module {
        return Err(CommandError::new(format!(
            "the run.ts adapter is only supported for Module commands; '{}' is a System command",
            command.address
        )));
    }
    if command.adapter == CommandAdapter::Runtime && command.space != CommandSpace::System {
        return Err(CommandError::new(format!(
            "Runtime Component execution is only supported for System commands; '{}' has an invalid owner",
            command.address
        )));
    }
    Ok(())
}
