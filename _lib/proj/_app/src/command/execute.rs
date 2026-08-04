use std::ffi::OsString;

use crate::catalog::CatalogSnapshot;

use super::{
    CommandExecutionContext, CommandResult, ExecutionPhase, GuardPlan, Invocation,
    ProcessEnvironment, process::run_process,
};

pub struct CommandExecutor<'a> {
    context: &'a CommandExecutionContext,
    catalog: &'a CatalogSnapshot,
}

impl<'a> CommandExecutor<'a> {
    pub fn new(context: &'a CommandExecutionContext, catalog: &'a CatalogSnapshot) -> Self {
        Self { context, catalog }
    }

    pub fn execute(&self, argv: &[OsString]) -> CommandResult<i32> {
        let invocation = Invocation::resolve(self.catalog, argv)?;
        let guard_plan = GuardPlan::discover(&self.context.kernel_root, &invocation.command)?;

        for guard in guard_plan.guards {
            let environment = ProcessEnvironment::for_command(
                self.context,
                &invocation.command,
                ExecutionPhase::Guard(guard.scope),
                invocation.help_target_address.as_deref(),
            );
            let exit_code = run_process(
                guard.adapter,
                &guard.entry_path,
                &[],
                &self.context.project_root,
                &environment,
            )?;
            if exit_code != 0 {
                return Ok(exit_code);
            }
        }

        let environment = ProcessEnvironment::for_command(
            self.context,
            &invocation.command,
            ExecutionPhase::Run,
            invocation.help_target_address.as_deref(),
        );
        run_process(
            invocation.command.adapter,
            &invocation.command.entry_path,
            &invocation.arguments,
            &self.context.project_root,
            &environment,
        )
    }
}
