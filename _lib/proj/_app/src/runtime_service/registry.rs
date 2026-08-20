mod operation_control;
mod query;
mod run;

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex};

use crate::run_journal::{RunJournal, StartRunJournal};

use super::execution::{PreparedExecution, RuntimeExecutionRunner};
use super::{CommandRunDocument, RuntimeQueryOutput, RuntimeServiceError};
use operation_control::OperationControl;
use query::{QueryOperation, run_query};
use run::{CommandRun, RunObserver};

#[cfg(test)]
use super::CommandRunState;
#[cfg(test)]
use run::MAX_OUTPUT_EVENTS;

const MAX_ACTIVE_OPERATIONS: usize = 4;
const MAX_TERMINAL_RUNS: usize = 32;

#[derive(Clone)]
pub(super) struct RunRegistry {
    inner: Arc<RegistryInner>,
}

impl RunRegistry {
    pub fn new(runner: Arc<dyn RuntimeExecutionRunner>) -> Self {
        Self {
            inner: Arc::new(RegistryInner {
                runner,
                state: Mutex::new(RegistryState::default()),
            }),
        }
    }

    pub fn start(
        &self,
        execution: PreparedExecution,
        journal_request: StartRunJournal,
    ) -> Result<CommandRunDocument, RuntimeServiceError> {
        let address = execution.address().to_owned();
        let cancelable = execution.cancelable();
        let run = {
            let mut state = self.inner.lock()?;
            prune_terminal(&mut state);
            state.reserve()?;
            let journal = match RunJournal::start(journal_request) {
                Ok(journal) => journal,
                Err(error) => {
                    state.active -= 1;
                    return Err(RuntimeServiceError::Journal(error));
                }
            };
            let id = match journal.id() {
                Ok(id) => id,
                Err(error) => {
                    state.active -= 1;
                    return Err(RuntimeServiceError::Journal(error));
                }
            };
            let run = Arc::new(CommandRun::new(id.clone(), address, journal, cancelable));
            state.order.push_back(id.clone());
            state.runs.insert(id, Arc::clone(&run));
            run
        };

        let observer = Arc::new(RunObserver {
            run: Arc::downgrade(&run),
            registry: Arc::downgrade(&self.inner),
        });
        match self.inner.runner.start(execution, observer) {
            Ok(control) => {
                run.attach_control(control)?;
                run.document(0)
            }
            Err(error) => {
                run.fail_start(format!("cannot start the Runtime execution: {error}"));
                let remove_result = self.inner.remove_failed_start(&run);
                let control_result = run.start_failed();
                remove_result?;
                control_result?;
                Err(RuntimeServiceError::Start(error))
            }
        }
    }

    pub fn get(&self, id: &str, after: u64) -> Result<CommandRunDocument, RuntimeServiceError> {
        self.inner.run(id)?.document(after)
    }

    pub fn cancel(&self, id: &str) -> Result<(), RuntimeServiceError> {
        self.inner.run(id)?.cancel()
    }

    pub fn query(
        &self,
        execution: PreparedExecution,
    ) -> Result<RuntimeQueryOutput, RuntimeServiceError> {
        let registration = self.inner.register_query(execution.cancelable())?;
        run_query(Arc::clone(&self.inner.runner), execution, registration)
            .map_err(RuntimeServiceError::Query)
    }

    pub fn shutdown(&self) -> Result<(), RuntimeServiceError> {
        let (runs, queries) = {
            let mut state = self.inner.lock()?;
            state.accepting = false;
            (
                state.runs.values().cloned().collect::<Vec<_>>(),
                state.queries.values().cloned().collect::<Vec<_>>(),
            )
        };

        let mut errors = Vec::new();

        // Cancellation is deliberately two-phase. Every operation is marked before any
        // pending runner.start call is awaited, so a late control attachment is canceled
        // immediately instead of escaping shutdown.
        for run in &runs {
            if let Err(error) = run.begin_shutdown_cancel() {
                errors.push(error.to_string());
            }
        }
        for query in &queries {
            if let Err(error) = query.begin_shutdown_cancel() {
                errors.push(error.to_string());
            }
        }
        for run in &runs {
            if let Err(error) = run.finish_shutdown_cancel() {
                errors.push(error.to_string());
            }
        }
        for query in &queries {
            if let Err(error) = query.finish_shutdown_cancel() {
                errors.push(error.to_string());
            }
        }
        for run in runs {
            if let Err(error) = run.join_control() {
                errors.push(error);
            }
        }
        for query in queries {
            if let Err(error) = query.join_control() {
                errors.push(error);
            }
        }

        if errors.is_empty() {
            Ok(())
        } else {
            Err(RuntimeServiceError::Shutdown(errors.join("; ")))
        }
    }
}

struct RegistryInner {
    runner: Arc<dyn RuntimeExecutionRunner>,
    state: Mutex<RegistryState>,
}

impl RegistryInner {
    fn lock(&self) -> Result<std::sync::MutexGuard<'_, RegistryState>, RuntimeServiceError> {
        self.state
            .lock()
            .map_err(|_| RuntimeServiceError::RegistryUnavailable)
    }

    fn run(&self, id: &str) -> Result<Arc<CommandRun>, RuntimeServiceError> {
        self.lock()?
            .runs
            .get(id)
            .cloned()
            .ok_or(RuntimeServiceError::RunNotFound)
    }

    fn register_query(
        self: &Arc<Self>,
        cancelable: bool,
    ) -> Result<QueryRegistration, RuntimeServiceError> {
        let mut state = self.lock()?;
        state.reserve()?;
        let id = state.next_query_id;
        state.next_query_id = state.next_query_id.wrapping_add(1);
        let query = Arc::new(QueryOperation::new(cancelable));
        state.queries.insert(id, Arc::clone(&query));
        Ok(QueryRegistration {
            registry: Arc::clone(self),
            id,
            operation: query,
        })
    }

    fn remove_failed_start(&self, run: &CommandRun) -> Result<(), RuntimeServiceError> {
        let mut state = self.lock()?;
        if state.runs.remove(&run.id).is_some() {
            state.order.retain(|id| id != &run.id);
            state.active = state.active.saturating_sub(1);
        }
        Ok(())
    }

    fn completed_run(&self) {
        let Ok(mut state) = self.state.lock() else {
            return;
        };
        state.active = state.active.saturating_sub(1);
        prune_terminal(&mut state);
    }

    fn completed_query(&self, id: u64) {
        let Ok(mut state) = self.state.lock() else {
            return;
        };
        if state.queries.remove(&id).is_some() {
            state.active = state.active.saturating_sub(1);
        }
    }
}

pub(super) struct QueryRegistration {
    registry: Arc<RegistryInner>,
    id: u64,
    operation: Arc<QueryOperation>,
}

impl QueryRegistration {
    fn operation(&self) -> Arc<QueryOperation> {
        Arc::clone(&self.operation)
    }
}

impl Drop for QueryRegistration {
    fn drop(&mut self) {
        self.registry.completed_query(self.id);
    }
}

struct RegistryState {
    accepting: bool,
    active: usize,
    next_query_id: u64,
    order: VecDeque<String>,
    runs: HashMap<String, Arc<CommandRun>>,
    queries: HashMap<u64, Arc<QueryOperation>>,
}

impl RegistryState {
    fn reserve(&mut self) -> Result<(), RuntimeServiceError> {
        if !self.accepting {
            return Err(RuntimeServiceError::ShuttingDown);
        }
        if self.active >= MAX_ACTIVE_OPERATIONS {
            return Err(RuntimeServiceError::Capacity);
        }
        self.active += 1;
        Ok(())
    }
}

impl Default for RegistryState {
    fn default() -> Self {
        Self {
            accepting: true,
            active: 0,
            next_query_id: 0,
            order: VecDeque::new(),
            runs: HashMap::new(),
            queries: HashMap::new(),
        }
    }
}

fn prune_terminal(state: &mut RegistryState) {
    let mut terminal = state.runs.values().filter(|run| run.is_terminal()).count();
    if terminal <= MAX_TERMINAL_RUNS {
        return;
    }
    let mut removed = Vec::new();
    for id in &state.order {
        if terminal <= MAX_TERMINAL_RUNS {
            break;
        }
        if state.runs.get(id).is_some_and(|run| run.is_terminal()) {
            removed.push(id.clone());
            terminal -= 1;
        }
    }
    for id in &removed {
        state.runs.remove(id);
    }
    state.order.retain(|id| !removed.contains(id));
}

#[cfg(test)]
mod tests;
