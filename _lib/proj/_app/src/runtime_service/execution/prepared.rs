use std::ffi::OsString;
use std::path::PathBuf;

use crate::catalog::CatalogSnapshot;
use crate::command::{CommandExecutionContext, CommandExecutor, PlannedCommand};
use crate::core_command::{CoreCommandOutcome, PreparedCoreCommand};
use crate::process_runner::ProcessLaunch;

/// A command whose logical resolution and dependency check have completed.
///
/// The Runtime starts the Run Journal before handing this value to an
/// execution runner. Core argument handling and every process materialization
/// step therefore remain on the journaled side of the observable-work
/// boundary.
pub(crate) struct PreparedExecution {
    spec: RuntimeExecutionSpec,
    pub(super) kind: PreparedExecutionKind,
}

impl PreparedExecution {
    pub(crate) fn core(spec: RuntimeExecutionSpec, command: PreparedCoreCommand) -> Self {
        Self {
            spec,
            kind: PreparedExecutionKind::Core(Box::new(NativeCoreTask(command))),
        }
    }

    pub(crate) fn process(
        spec: RuntimeExecutionSpec,
        context: CommandExecutionContext,
        catalog: CatalogSnapshot,
        plan: PlannedCommand,
    ) -> Self {
        Self {
            spec,
            kind: PreparedExecutionKind::Process(Box::new(OwnedProcessPlan {
                context,
                catalog,
                plan,
            })),
        }
    }

    #[cfg(test)]
    pub(super) fn core_fixture(spec: RuntimeExecutionSpec, task: impl CoreTask + 'static) -> Self {
        Self {
            spec,
            kind: PreparedExecutionKind::Core(Box::new(task)),
        }
    }

    #[cfg(test)]
    pub(super) fn process_fixture(
        spec: RuntimeExecutionSpec,
        task: impl ProcessTask + 'static,
    ) -> Self {
        Self {
            spec,
            kind: PreparedExecutionKind::Process(Box::new(task)),
        }
    }

    #[cfg(test)]
    pub(crate) fn fixture(spec: RuntimeExecutionSpec) -> Self {
        Self::core_fixture(spec, FixtureCoreTask)
    }

    #[cfg(test)]
    pub(crate) fn cancelable_fixture(spec: RuntimeExecutionSpec) -> Self {
        Self::process_fixture(spec, FixtureProcessTask)
    }

    pub(crate) fn address(&self) -> &str {
        &self.spec.address
    }

    pub(crate) fn argument_count(&self) -> usize {
        self.spec.argv.len().saturating_sub(1)
    }

    #[cfg(test)]
    pub(crate) fn argv(&self) -> &[OsString] {
        &self.spec.argv
    }

    #[cfg(test)]
    pub(crate) fn arguments(&self) -> &[OsString] {
        self.spec.arguments()
    }

    #[cfg(test)]
    pub(crate) fn working_directory(&self) -> &std::path::Path {
        &self.spec.working_directory
    }

    pub(crate) fn cancelable(&self) -> bool {
        matches!(&self.kind, PreparedExecutionKind::Process(_))
    }
}

/// Transport-neutral identity retained for diagnostics and test runners.
/// It intentionally contains no resolved executable or environment snapshot.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RuntimeExecutionSpec {
    address: String,
    argv: Vec<OsString>,
    working_directory: PathBuf,
}

impl RuntimeExecutionSpec {
    pub(crate) fn new(
        address: impl Into<String>,
        argv: Vec<OsString>,
        working_directory: impl Into<PathBuf>,
    ) -> Self {
        Self {
            address: address.into(),
            argv,
            working_directory: working_directory.into(),
        }
    }

    #[cfg(test)]
    pub(crate) fn argv(&self) -> &[OsString] {
        &self.argv
    }

    #[cfg(test)]
    pub(crate) fn arguments(&self) -> &[OsString] {
        self.argv.get(1..).unwrap_or_default()
    }

    #[cfg(test)]
    pub(crate) fn working_directory(&self) -> &std::path::Path {
        &self.working_directory
    }

    #[cfg(test)]
    pub(crate) fn argument_count(&self) -> usize {
        self.argv.len().saturating_sub(1)
    }
}

pub(super) enum PreparedExecutionKind {
    Core(Box<dyn CoreTask>),
    Process(Box<dyn ProcessTask>),
}

#[cfg(test)]
struct FixtureCoreTask;

#[cfg(test)]
impl CoreTask for FixtureCoreTask {
    fn execute(self: Box<Self>) -> Result<CoreCommandOutcome, String> {
        Ok(CoreCommandOutcome::success(String::new()))
    }
}

#[cfg(test)]
struct FixtureProcessTask;

#[cfg(test)]
impl ProcessTask for FixtureProcessTask {
    fn materialize(self: Box<Self>) -> Result<ProcessLaunch, String> {
        panic!("fixture process execution must be consumed by a fake runner")
    }
}

pub(super) trait CoreTask: Send {
    fn execute(self: Box<Self>) -> Result<CoreCommandOutcome, String>;
}

struct NativeCoreTask(PreparedCoreCommand);

impl CoreTask for NativeCoreTask {
    fn execute(self: Box<Self>) -> Result<CoreCommandOutcome, String> {
        self.0.execute().map_err(|error| error.to_string())
    }
}

pub(super) trait ProcessTask: Send {
    fn materialize(self: Box<Self>) -> Result<ProcessLaunch, String>;
}

struct OwnedProcessPlan {
    context: CommandExecutionContext,
    catalog: CatalogSnapshot,
    plan: PlannedCommand,
}

impl ProcessTask for OwnedProcessPlan {
    fn materialize(self: Box<Self>) -> Result<ProcessLaunch, String> {
        CommandExecutor::new(&self.context, &self.catalog)
            .materialize(self.plan)
            .and_then(|command| command.materialize_process_launch())
            .map_err(|error| error.to_string())
    }
}
