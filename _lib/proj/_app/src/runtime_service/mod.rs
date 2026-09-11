mod error;
mod execution;
mod model;
mod registry;

use std::ffi::OsString;
use std::sync::Arc;

use crate::catalog::{CatalogSnapshot, CommandAdapter, CommandSpace};
use crate::command::{CommandExecutionContext, Invocation, PlannedCommand, command_data_root};
use crate::context::EntryContext;
use crate::core_command::PreparedCoreCommand;
use crate::data_root::DataRootSession;
use crate::entry_config::EntryConfigStore;
use crate::route_resolution::{
    CommandQuery, ResolvedFacetCall, RouteResolutionError, RouteResolver,
};
use crate::run_journal::StartRunJournal;

pub(crate) use error::RuntimeServiceError;
use execution::NativeRuntimeExecutionRunner;
pub(crate) use execution::{PreparedExecution, RuntimeExecutionRunner, RuntimeExecutionSpec};
use model::validate_invocation;
pub(crate) use model::{
    COMMAND_RUN_PROTOCOL, CommandRunDocument, CommandRunState, RuntimeQueryOutput,
    StartFacetRunRequest,
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

    pub(crate) async fn submit_facet(
        &self,
        request: StartFacetRunRequest,
    ) -> Result<CommandRunDocument, RuntimeServiceError> {
        request
            .validate()
            .map_err(RuntimeServiceError::InvalidRequest)?;
        self.require_current_generation()?;
        let prepared = self
            .prepare_facet_submission(request.route, request.tail)
            .await?;
        self.start_prepared(prepared, request.source).await
    }

    async fn start_prepared(
        &self,
        prepared: PreparedRun,
        source: crate::run_journal::RunJournalSource,
    ) -> Result<CommandRunDocument, RuntimeServiceError> {
        let journal_request = StartRunJournal {
            module_data_root: prepared.journal.module_data_root,
            address: prepared.execution.address().to_owned(),
            source,
            argument_count: prepared.execution.argument_count(),
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
        self.require_current_generation()?;
        let data_root = self.data_root.resolved();
        let prepared = prepare_command(
            self.clone(),
            self.context.clone(),
            data_root.path().to_path_buf(),
            address.to_owned(),
            arguments.to_vec(),
        )?;
        self.runs.query(prepared.execution)
    }

    pub(crate) fn shutdown(&self) -> Result<(), RuntimeServiceError> {
        self.runs.shutdown()
    }

    pub(crate) fn require_current_generation(&self) -> Result<(), RuntimeServiceError> {
        let selected_release_id = crate::runtime_release::selected_release_id(&self.context)
            .map_err(|error| {
                RuntimeServiceError::RuntimeGenerationUnavailable(error.to_string())
            })?;
        if selected_release_id != self.context.release_id {
            return Err(RuntimeServiceError::RuntimeUpdateRequired {
                running_release_id: self.context.release_id.clone(),
                selected_release_id,
            });
        }
        Ok(())
    }

    async fn prepare_facet_submission(
        &self,
        route: swawkit_proj_protocol::FacetRoute,
        tail: Vec<String>,
    ) -> Result<PreparedRun, RuntimeServiceError> {
        let data_root = self.data_root.resolved();
        let context = self.context.clone();
        let data_root_path = data_root.path().to_path_buf();
        let runtime_service = self.clone();
        let prepared = tokio::task::spawn_blocking(move || {
            prepare_facet_command(runtime_service, context, data_root_path, route, tail)
        })
        .await
        .map_err(|error| RuntimeServiceError::PreparationWorker(error.to_string()))??;
        Ok(PreparedRun {
            execution: prepared.execution,
            journal: prepared.journal,
        })
    }
}

struct PreparedRun {
    execution: PreparedExecution,
    journal: PreparedJournal,
}

struct PreparedJournal {
    module_data_root: std::path::PathBuf,
}

struct PreparedCommand {
    execution: PreparedExecution,
    journal: PreparedJournal,
}

fn prepare_command(
    runtime_service: RuntimeService,
    context: EntryContext,
    data_root: std::path::PathBuf,
    address: String,
    arguments: Vec<String>,
) -> Result<PreparedCommand, RuntimeServiceError> {
    let config_store = EntryConfigStore::new(&context.swawkit_home, &data_root);
    let config_state = config_store.read();
    let config = config_state.ready().cloned();
    let catalog = CatalogSnapshot::discover(&context, config.as_ref())
        .map_err(|_| RuntimeServiceError::CatalogDiscovery)?;
    prepare_command_in_catalog(
        runtime_service,
        context,
        data_root,
        config,
        catalog,
        address,
        arguments,
    )
}

fn prepare_facet_command(
    runtime_service: RuntimeService,
    context: EntryContext,
    data_root: std::path::PathBuf,
    route: swawkit_proj_protocol::FacetRoute,
    tail: Vec<String>,
) -> Result<PreparedCommand, RuntimeServiceError> {
    let config_store = EntryConfigStore::new(&context.swawkit_home, &data_root);
    let config_state = config_store.read();
    let config = config_state.ready().cloned();
    let catalog = CatalogSnapshot::discover(&context, config.as_ref())
        .map_err(|_| RuntimeServiceError::CatalogDiscovery)?;
    let invocation = {
        let query = SnapshotCommandQuery {
            runtime_service: &runtime_service,
            context: &context,
            data_root: &data_root,
            config: config.as_ref(),
            catalog: &catalog,
        };
        match RouteResolver::new(&catalog, &query)
            .resolve_facet_call(&route)
            .map_err(map_route_resolution_error)?
        {
            ResolvedFacetCall::Invocation(invocation) => invocation,
            ResolvedFacetCall::Document(_) => {
                return Err(RuntimeServiceError::CommandInvalid(
                    "only operation Facets can start command runs".to_owned(),
                ));
            }
        }
    };
    if !tail.is_empty() && !invocation.accepts_tail {
        return Err(RuntimeServiceError::InvalidRequest(
            "the requested operation Facet does not accept trailing arguments",
        ));
    }
    let mut arguments = invocation.arguments;
    arguments.extend(tail);
    validate_invocation(&invocation.address, &arguments)
        .map_err(RuntimeServiceError::InvalidRequest)?;
    prepare_command_in_catalog(
        runtime_service,
        context,
        data_root,
        config,
        catalog,
        invocation.address,
        arguments,
    )
}

struct SnapshotCommandQuery<'a> {
    runtime_service: &'a RuntimeService,
    context: &'a EntryContext,
    data_root: &'a std::path::Path,
    config: Option<&'a crate::entry_config::EntryConfig>,
    catalog: &'a CatalogSnapshot,
}

impl CommandQuery for SnapshotCommandQuery<'_> {
    fn query(
        &self,
        address: &str,
        arguments: &[String],
    ) -> Result<RuntimeQueryOutput, RuntimeServiceError> {
        validate_invocation(address, arguments).map_err(RuntimeServiceError::InvalidRequest)?;
        self.runtime_service.require_current_generation()?;
        let prepared = prepare_command_in_catalog(
            self.runtime_service.clone(),
            self.context.clone(),
            self.data_root.to_path_buf(),
            self.config.cloned(),
            self.catalog.clone(),
            address.to_owned(),
            arguments.to_vec(),
        )?;
        self.runtime_service.runs.query(prepared.execution)
    }
}

fn map_route_resolution_error(error: RouteResolutionError) -> RuntimeServiceError {
    match error {
        RouteResolutionError::NotFound(_) => RuntimeServiceError::CommandNotFound,
        RouteResolutionError::Invalid(message) => RuntimeServiceError::CommandInvalid(message),
        RouteResolutionError::Internal(message) => RuntimeServiceError::Query(message),
        RouteResolutionError::Runtime(error) => error,
    }
}

#[allow(clippy::too_many_arguments)]
fn prepare_command_in_catalog(
    runtime_service: RuntimeService,
    context: EntryContext,
    data_root: std::path::PathBuf,
    config: Option<crate::entry_config::EntryConfig>,
    catalog: CatalogSnapshot,
    address: String,
    arguments: Vec<String>,
) -> Result<PreparedCommand, RuntimeServiceError> {
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

    let execution_context =
        CommandExecutionContext::for_host(&context, config.as_ref(), &catalog, &data_root)
            .map_err(|error| RuntimeServiceError::ExecutionContext(error.to_string()))?;
    let journal = PreparedJournal {
        module_data_root: command_data_root(&execution_context, command)
            .map_err(|error| RuntimeServiceError::CommandDataRoot(error.to_string()))?,
    };

    let working_directory = if command.space == CommandSpace::Module
        && command.namespace.as_deref() == Some("project")
    {
        execution_context.project_root.clone().ok_or_else(|| {
            RuntimeServiceError::ExecutionContext(
                "project command has no bound project root".to_owned(),
            )
        })?
    } else {
        execution_context.working_directory.clone()
    };
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
                Arc::new(runtime_service),
            )
            .map_err(|error| RuntimeServiceError::CommandInvalid(error.to_string()))?,
        )
    } else {
        PreparedExecution::process(
            spec,
            execution_context,
            catalog,
            PlannedCommand::new(invocation),
        )
    };

    Ok(PreparedCommand { execution, journal })
}

#[cfg(test)]
mod tests;
