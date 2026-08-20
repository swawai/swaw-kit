mod error;
mod execution;
mod model;
mod registry;

use std::ffi::OsString;
use std::sync::Arc;

use crate::catalog::{CatalogSnapshot, CommandAdapter, CommandSpace};
use crate::command::{
    CommandExecutionContext, CommandProcessMode, Invocation, PlannedCommand, command_data_root,
};
use crate::context::EntryContext;
use crate::core_command::PreparedCoreCommand;
use crate::data_root::DataRootSession;
use crate::profile::{EntryProfileState, EntryProfileStore};
use crate::run_journal::StartRunJournal;

pub(crate) use error::RuntimeServiceError;
use execution::NativeRuntimeExecutionRunner;
pub(crate) use execution::{PreparedExecution, RuntimeExecutionRunner, RuntimeExecutionSpec};
use model::validate_invocation;
pub(crate) use model::{
    COMMAND_RUN_PROTOCOL, CommandRunDocument, CommandRunState, RuntimeQueryOutput,
    StartCommandRunRequest,
};
use registry::RunRegistry;

#[derive(Clone)]
pub(crate) struct RuntimeService {
    context: EntryContext,
    data_root: DataRootSession,
    runs: RunRegistry,
}

impl RuntimeService {
    pub(crate) fn native(context: EntryContext, data_root: DataRootSession) -> Self {
        Self::new(
            context,
            data_root,
            Arc::new(NativeRuntimeExecutionRunner::default()),
        )
    }

    pub(crate) fn new(
        context: EntryContext,
        data_root: DataRootSession,
        runner: Arc<dyn RuntimeExecutionRunner>,
    ) -> Self {
        Self {
            context,
            data_root,
            runs: RunRegistry::new(runner),
        }
    }

    pub(crate) async fn submit(
        &self,
        request: StartCommandRunRequest,
    ) -> Result<CommandRunDocument, RuntimeServiceError> {
        request
            .validate()
            .map_err(RuntimeServiceError::InvalidRequest)?;
        let prepared = self
            .prepare_submission(request.address, request.arguments)
            .await?;
        let journal_request = StartRunJournal {
            module_data_root: prepared.journal.module_data_root,
            address: prepared.execution.address().to_owned(),
            source: request.source,
            argument_count: prepared.execution.argument_count(),
            profile_revision: prepared.journal.profile_revision,
        };
        let runs = self.runs.clone();
        tokio::task::spawn_blocking(move || runs.start(prepared.execution, journal_request))
            .await
            .map_err(|error| RuntimeServiceError::RunWorker(error.to_string()))?
    }

    pub(crate) fn read(
        &self,
        id: &str,
        after: u64,
    ) -> Result<CommandRunDocument, RuntimeServiceError> {
        self.runs.get(id, after)
    }

    pub(crate) async fn cancel(&self, id: String) -> Result<(), RuntimeServiceError> {
        let runs = self.runs.clone();
        tokio::task::spawn_blocking(move || runs.cancel(&id))
            .await
            .map_err(|error| RuntimeServiceError::CancellationWorker(error.to_string()))?
    }

    pub(crate) fn query(
        &self,
        address: &str,
        arguments: &[String],
    ) -> Result<RuntimeQueryOutput, RuntimeServiceError> {
        validate_invocation(address, arguments).map_err(RuntimeServiceError::InvalidRequest)?;
        let data_root = self.data_root.resolved();
        let prepared = prepare_command(
            self.context.clone(),
            data_root.path().to_path_buf(),
            address.to_owned(),
            arguments.to_vec(),
            false,
        )?;
        self.runs.query(prepared.execution)
    }

    pub(crate) fn shutdown(&self) -> Result<(), RuntimeServiceError> {
        self.runs.shutdown()
    }

    async fn prepare_submission(
        &self,
        address: String,
        arguments: Vec<String>,
    ) -> Result<PreparedRun, RuntimeServiceError> {
        let data_root = self.data_root.resolved();
        let context = self.context.clone();
        let data_root_path = data_root.path().to_path_buf();
        let prepared = tokio::task::spawn_blocking(move || {
            prepare_command(context, data_root_path, address, arguments, true)
        })
        .await
        .map_err(|error| RuntimeServiceError::PreparationWorker(error.to_string()))??;
        Ok(PreparedRun {
            execution: prepared.execution,
            journal: prepared
                .journal
                .ok_or(RuntimeServiceError::ProfileSetupRequired)?,
        })
    }
}

struct PreparedRun {
    execution: PreparedExecution,
    journal: PreparedJournal,
}

struct PreparedJournal {
    module_data_root: std::path::PathBuf,
    profile_revision: String,
}

struct PreparedCommand {
    execution: PreparedExecution,
    journal: Option<PreparedJournal>,
}

fn prepare_command(
    mut context: EntryContext,
    data_root: std::path::PathBuf,
    address: String,
    arguments: Vec<String>,
    require_ready_profile: bool,
) -> Result<PreparedCommand, RuntimeServiceError> {
    let profile_store = EntryProfileStore::new(&context.swawkit_home, &data_root);
    let profile_state = profile_store.read();
    if require_ready_profile {
        require_profile(&profile_state)?;
    }
    let catalog = CatalogSnapshot::discover(&context, profile_state.ready())
        .map_err(|_| RuntimeServiceError::CatalogDiscovery)?;
    if !catalog
        .commands
        .iter()
        .any(|command| command.address == address)
    {
        return Err(RuntimeServiceError::CommandNotFound);
    }
    let mut argv = Vec::with_capacity(arguments.len() + 1);
    argv.push(OsString::from(&address));
    argv.extend(arguments.into_iter().map(OsString::from));
    let invocation = Invocation::resolve(&catalog, &argv)
        .map_err(|error| RuntimeServiceError::CommandInvalid(error.to_string()))?;
    let command = &invocation.command;
    if command.space == CommandSpace::System
        && command
            .path
            .first()
            .is_some_and(|segment| matches!(segment.as_str(), "entry" | "runtime"))
    {
        return Err(RuntimeServiceError::LifecycleCommandUnsupported);
    }
    crate::command_check::assert_dependencies_ready(
        &data_root,
        &context.entry_name,
        &catalog,
        &command.address,
    )
    .map_err(RuntimeServiceError::DependenciesNotReady)?;

    let working_directory = profile_state
        .ready()
        .map(|profile| profile.binding().target_project_root().to_path_buf())
        .unwrap_or_else(|| context.invocation_directory.clone());
    context.invocation_directory = working_directory.clone();
    let execution_context = profile_state
        .ready()
        .map(|profile| {
            CommandExecutionContext::new(
                &context,
                profile,
                &data_root,
                CommandProcessMode::NoWindow,
            )
            .map_err(|error| RuntimeServiceError::ExecutionContext(error.to_string()))
        })
        .transpose()?;
    let journal = execution_context
        .as_ref()
        .zip(profile_state.ready())
        .map(|(execution_context, profile)| {
            Ok(PreparedJournal {
                module_data_root: command_data_root(execution_context, command)
                    .map_err(|error| RuntimeServiceError::CommandDataRoot(error.to_string()))?,
                profile_revision: profile.profile_revision().to_owned(),
            })
        })
        .transpose()?;

    let spec = RuntimeExecutionSpec::new(address, argv.clone(), working_directory);
    let execution = if command.adapter == CommandAdapter::Core {
        PreparedExecution::core(
            spec,
            PreparedCoreCommand::for_runtime(
                command,
                argv,
                catalog,
                context,
                data_root,
                profile_state,
                profile_store,
            )
            .map_err(|error| RuntimeServiceError::CommandInvalid(error.to_string()))?,
        )
    } else {
        let execution_context = execution_context.ok_or_else(|| profile_error(&profile_state))?;
        PreparedExecution::process(
            spec,
            execution_context,
            catalog,
            PlannedCommand::new(invocation),
        )
    };

    Ok(PreparedCommand { execution, journal })
}

fn require_profile(state: &EntryProfileState) -> Result<(), RuntimeServiceError> {
    match state {
        EntryProfileState::Ready(_) => Ok(()),
        EntryProfileState::Missing { .. } => Err(RuntimeServiceError::ProfileSetupRequired),
        EntryProfileState::Invalid { error, .. } => {
            Err(RuntimeServiceError::ProfileInvalid(error.clone()))
        }
    }
}

fn profile_error(state: &EntryProfileState) -> RuntimeServiceError {
    require_profile(state).expect_err("non-ready profile must have a typed error")
}

#[cfg(test)]
mod tests;
