use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use crate::command_event::CommandProgress;
use crate::process_runner::{ProcessObserver, ProcessOutcome, ProcessOutputStream};
use crate::runtime_service::RuntimeQueryOutput;
use crate::runtime_service::execution::{PreparedExecution, RuntimeExecutionRunner};

use super::{OperationControl, QueryRegistration};

const QUERY_TIMEOUT: Duration = Duration::from_secs(15);
const MAX_QUERY_OUTPUT_BYTES: usize = 1024 * 1024;

pub(super) fn run_query(
    runner: Arc<dyn RuntimeExecutionRunner>,
    execution: PreparedExecution,
    registration: QueryRegistration,
) -> Result<RuntimeQueryOutput, String> {
    run_query_with(
        runner,
        execution,
        registration,
        QUERY_TIMEOUT,
        MAX_QUERY_OUTPUT_BYTES,
    )
}

fn run_query_with(
    runner: Arc<dyn RuntimeExecutionRunner>,
    execution: PreparedExecution,
    registration: QueryRegistration,
    timeout: Duration,
    max_output_bytes: usize,
) -> Result<RuntimeQueryOutput, String> {
    let operation = registration.operation();
    operation.observer.set_max_output_bytes(max_output_bytes)?;
    let observer: Arc<dyn ProcessObserver> = operation.observer.clone();
    let control = match runner.start(execution, observer) {
        Ok(control) => control,
        Err(error) => {
            operation
                .control
                .start_failed()
                .map_err(|state_error| state_error.to_string())?;
            return Err(format!("cannot start the facet query: {error}"));
        }
    };
    operation
        .control
        .attach(control)
        .map_err(|error| error.to_string())?;

    let wait = operation.observer.wait(timeout);
    if operation.cancelable && matches!(wait, QueryWait::TimedOut | QueryWait::Rejected(_)) {
        let _ = operation.control.cancel();
    }
    let join = operation.control.join();
    let state = operation.observer.snapshot()?;
    join.map_err(|error| format!("cannot join the facet query: {error}"))?;

    match wait {
        QueryWait::TimedOut => return Err("facet query timed out".to_owned()),
        QueryWait::Rejected(error) => return Err(error),
        QueryWait::Completed => {}
    }
    let exit_code = match state.outcome {
        Some(ProcessOutcome::Exited(exit_code)) => exit_code,
        Some(ProcessOutcome::Failed(error)) => {
            return Err(format!("facet query failed: {error}"));
        }
        None => return Err("facet query completed without an outcome".to_owned()),
    };
    if !state.stderr.is_empty() {
        return Err("facet query wrote to stderr".to_owned());
    }
    Ok(RuntimeQueryOutput {
        stdout: state.stdout,
        exit_code,
    })
}

pub(super) struct QueryOperation {
    observer: Arc<QueryObserver>,
    control: OperationControl,
    cancelable: bool,
}

impl QueryOperation {
    pub(super) fn new(cancelable: bool) -> Self {
        Self {
            observer: Arc::new(QueryObserver::new()),
            control: OperationControl::new(),
            cancelable,
        }
    }

    pub(super) fn begin_shutdown_cancel(&self) -> std::io::Result<()> {
        if !self.cancelable {
            return Ok(());
        }
        self.observer
            .reject("facet query canceled because the runtime service is shutting down");
        self.control.begin_cancel()
    }

    pub(super) fn finish_shutdown_cancel(&self) -> std::io::Result<()> {
        if self.cancelable {
            self.control.cancel_result()
        } else {
            Ok(())
        }
    }

    pub(super) fn join_control(&self) -> Result<(), String> {
        self.control.join()
    }
}

struct QueryObserver {
    state: Mutex<QueryState>,
    completed: Condvar,
}

impl QueryObserver {
    fn new() -> Self {
        Self {
            state: Mutex::new(QueryState {
                max_output_bytes: MAX_QUERY_OUTPUT_BYTES,
                ..QueryState::default()
            }),
            completed: Condvar::new(),
        }
    }

    fn set_max_output_bytes(&self, max_output_bytes: usize) -> Result<(), String> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| "facet query state is unavailable".to_owned())?;
        state.max_output_bytes = max_output_bytes;
        Ok(())
    }

    fn wait(&self, timeout: Duration) -> QueryWait {
        let Ok(state) = self.state.lock() else {
            return QueryWait::Rejected("facet query state is unavailable".to_owned());
        };
        let Ok((state, result)) = self.completed.wait_timeout_while(state, timeout, |state| {
            state.outcome.is_none() && state.rejection.is_none()
        }) else {
            return QueryWait::Rejected("facet query state is unavailable".to_owned());
        };
        if let Some(error) = &state.rejection {
            QueryWait::Rejected(error.clone())
        } else if state.outcome.is_some() {
            QueryWait::Completed
        } else if result.timed_out() {
            QueryWait::TimedOut
        } else {
            QueryWait::Rejected("facet query wait ended without an outcome".to_owned())
        }
    }

    fn snapshot(&self) -> Result<QueryState, String> {
        self.state
            .lock()
            .map(|state| state.clone())
            .map_err(|_| "facet query state is unavailable".to_owned())
    }

    fn reject(&self, error: &'static str) {
        if let Ok(mut state) = self.state.lock()
            && state.rejection.is_none()
            && state.outcome.is_none()
        {
            state.rejection = Some(error.to_owned());
        }
        self.completed.notify_all();
    }
}

impl ProcessObserver for QueryObserver {
    fn output(&self, stream: ProcessOutputStream, text: String) {
        if text.is_empty() {
            return;
        }
        let accepted = if let Ok(mut state) = self.state.lock() {
            let next_size = state.output_bytes.checked_add(text.len());
            if state.rejection.is_some()
                || next_size.is_none_or(|size| size > state.max_output_bytes)
            {
                false
            } else {
                state.output_bytes = next_size.expect("bounded output size");
                match stream {
                    ProcessOutputStream::Stdout => state.stdout.push_str(&text),
                    ProcessOutputStream::Stderr => state.stderr.push_str(&text),
                }
                true
            }
        } else {
            false
        };
        if !accepted {
            self.reject("facet query output exceeded the byte limit");
        } else if stream == ProcessOutputStream::Stderr {
            self.reject("facet query wrote to stderr");
        }
    }

    fn progress(&self, _progress: CommandProgress) {
        self.reject("facet query emitted a progress event");
    }

    fn completed(&self, outcome: ProcessOutcome) {
        if let Ok(mut state) = self.state.lock()
            && state.outcome.is_none()
        {
            state.outcome = Some(outcome);
        }
        self.completed.notify_all();
    }
}

#[derive(Clone, Default)]
struct QueryState {
    stdout: String,
    stderr: String,
    output_bytes: usize,
    max_output_bytes: usize,
    outcome: Option<ProcessOutcome>,
    rejection: Option<String>,
}

enum QueryWait {
    Completed,
    Rejected(String),
    TimedOut,
}

#[cfg(test)]
mod tests;
