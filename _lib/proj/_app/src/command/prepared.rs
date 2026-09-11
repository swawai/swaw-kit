use std::ffi::OsString;
use std::path::PathBuf;

use crate::catalog::CommandAdapter;
use crate::process_environment::current_user_environment;
use crate::process_runner::ProcessLaunch;
use crate::run_journal::{RunJournal, RunJournalPhase};

use super::{
    CommandError, CommandProcessMode, CommandResult, Invocation, ProcessEnvironment,
    process::{
        AdapterLaunch, materialize_isolated_command, process_creation_flags, run_process,
        run_process_journaled,
    },
};

/// A logical invocation whose dependency check has passed.
///
/// This value deliberately contains no resolved adapter artifact, framework
/// environment projection, current-user environment snapshot, or OS command.
/// It is therefore safe to create before a Run Journal starts. Materializing
/// it is a distinct, later side-effect boundary; the plan is still per-run
/// state and is not a durable queue payload.
pub(crate) struct PlannedCommand {
    invocation: Invocation,
}

impl PlannedCommand {
    pub(crate) fn new(invocation: Invocation) -> Self {
        Self { invocation }
    }

    pub(super) fn into_invocation(self) -> Invocation {
        self.invocation
    }

    pub(crate) fn command(&self) -> &super::ResolvedCommand {
        &self.invocation.command
    }

    pub(crate) fn argument_count(&self) -> usize {
        self.invocation.arguments.len()
    }
}

/// An owned, adapter-materialized invocation for one command entry.
///
/// Preparation owns the resolved target, arguments, working directory,
/// adapter artifact, and framework environment overlay. The child OS working
/// directory is the target project root; the original per-run invocation
/// directory remains explicit in `SWAWKIT_PROJ_CORE_COMMAND_INVOCATION_DIR`.
///
/// The fresh current-user environment is intentionally not captured here.
/// Call [`Self::materialize_process_launch`] immediately before
/// [`crate::process_runner::ProcessRunner::start`]. Neither this value nor the
/// resulting launch is a durable queue payload: adapter artifacts and the user
/// environment can change while a long-lived Host is running.
pub(crate) struct PreparedCommand {
    adapter: CommandAdapter,
    entry_path: PathBuf,
    arguments: Vec<OsString>,
    working_directory: PathBuf,
    adapter_launch: AdapterLaunch,
    environment: ProcessEnvironment,
    process_mode: CommandProcessMode,
}

impl PreparedCommand {
    #[allow(clippy::too_many_arguments)]
    pub(super) fn new(
        adapter: CommandAdapter,
        entry_path: PathBuf,
        arguments: Vec<OsString>,
        working_directory: PathBuf,
        adapter_launch: AdapterLaunch,
        environment: ProcessEnvironment,
        process_mode: CommandProcessMode,
    ) -> Self {
        Self {
            adapter,
            entry_path,
            arguments,
            working_directory,
            adapter_launch,
            environment,
            process_mode,
        }
    }

    pub(super) fn execute(&self) -> CommandResult<i32> {
        run_process(
            self.adapter,
            &self.entry_path,
            &self.arguments,
            &self.working_directory,
            &self.adapter_launch,
            &self.environment,
            self.process_mode,
        )
    }

    pub(super) fn execute_journaled(&self, journal: &RunJournal) -> CommandResult<i32> {
        run_process_journaled(
            self.adapter,
            &self.entry_path,
            &self.arguments,
            &self.working_directory,
            &self.adapter_launch,
            &self.environment,
            self.process_mode,
            journal,
            RunJournalPhase::Run,
        )
    }

    /// Builds one isolated launch recipe for the common process supervisor.
    ///
    /// The recipe clears the Host environment, installs a fresh current-user
    /// baseline with inherited `SWAWKIT_HOME` and `SWAWKIT_PROJ_*` state
    /// filtered out, then applies the command's explicit framework overlay.
    /// For `run.cmd`, `ComSpec` is also resolved and validated from this exact
    /// baseline, so spawning never consults the long-lived Host's ambient
    /// environment.
    pub(crate) fn materialize_process_launch(&self) -> CommandResult<ProcessLaunch> {
        let baseline = current_user_environment().map_err(|error| {
            CommandError::new(format!(
                "cannot capture the current-user command environment: {error}"
            ))
        })?;
        self.materialize_process_launch_with_environment(&baseline)
    }

    fn materialize_process_launch_with_environment(
        &self,
        baseline: &[(OsString, OsString)],
    ) -> CommandResult<ProcessLaunch> {
        let command = materialize_isolated_command(
            self.adapter,
            &self.entry_path,
            &self.arguments,
            &self.working_directory,
            &self.adapter_launch,
            &self.environment,
            baseline,
        )?;
        Ok(ProcessLaunch::new(
            command,
            "command entry",
            process_creation_flags(self.process_mode),
        ))
    }

    #[cfg(test)]
    pub(super) fn adapter(&self) -> CommandAdapter {
        self.adapter
    }

    #[cfg(test)]
    pub(super) fn entry_path(&self) -> &std::path::Path {
        &self.entry_path
    }

    #[cfg(test)]
    pub(super) fn arguments(&self) -> &[OsString] {
        &self.arguments
    }

    #[cfg(test)]
    pub(super) fn working_directory(&self) -> &std::path::Path {
        &self.working_directory
    }

    #[cfg(test)]
    pub(super) fn environment(&self) -> &ProcessEnvironment {
        &self.environment
    }

    #[cfg(test)]
    pub(super) fn adapter_launch(&self) -> &AdapterLaunch {
        &self.adapter_launch
    }

    #[cfg(test)]
    pub(super) fn materialize_process_launch_with_baseline(
        &self,
        baseline: &[(OsString, OsString)],
    ) -> CommandResult<ProcessLaunch> {
        self.materialize_process_launch_with_environment(baseline)
    }
}
