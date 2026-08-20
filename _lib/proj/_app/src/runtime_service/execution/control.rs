use std::io;
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;

use crate::process_runner::ProcessControl;

pub(super) struct DeferredExecutionControl {
    cancellation: CancellationPolicy,
    child: Mutex<ChildState>,
    completion: WorkerCompletion,
}

impl DeferredExecutionControl {
    pub(super) fn new(cancellation: CancellationPolicy) -> Self {
        Self {
            cancellation,
            child: Mutex::new(ChildState::default()),
            completion: WorkerCompletion {
                state: Mutex::new(WorkerJoinState::Pending),
                changed: Condvar::new(),
            },
        }
    }

    pub(super) fn attach_worker(&self, worker: JoinHandle<Result<(), String>>) {
        let mut state = self
            .completion
            .state
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        debug_assert!(matches!(*state, WorkerJoinState::Pending));
        *state = WorkerJoinState::Ready(Some(worker));
        self.completion.changed.notify_all();
    }

    /// Installs the process control and reports whether cancellation was
    /// requested while materialization or process start was still pending.
    pub(super) fn attach_child(&self, child: Arc<dyn ProcessControl>) -> bool {
        let mut state = self.child.lock().unwrap_or_else(|error| error.into_inner());
        debug_assert!(state.child.is_none());
        state.child = Some(child);
        state.cancel_requested
    }

    pub(super) fn finish_child(&self) {
        let mut state = self.child.lock().unwrap_or_else(|error| error.into_inner());
        state.child = None;
        state.finished = true;
    }

    pub(super) fn finish_without_child(&self) {
        let mut state = self.child.lock().unwrap_or_else(|error| error.into_inner());
        state.finished = true;
    }

    pub(super) fn abort_child(&self) {
        let child = {
            let mut state = self.child.lock().unwrap_or_else(|error| error.into_inner());
            state.finished = true;
            state.child.take()
        };
        if let Some(child) = child {
            let _ = child.cancel();
            let _ = child.join();
        }
    }
}

impl ProcessControl for DeferredExecutionControl {
    fn cancel(&self) -> io::Result<()> {
        let child = {
            let mut state = self
                .child
                .lock()
                .map_err(|_| io::Error::other("Runtime execution control is unavailable"))?;
            if state.finished {
                return Ok(());
            }
            if self.cancellation == CancellationPolicy::Unsupported {
                return Err(io::Error::other(
                    "an in-process Core command cannot be canceled after it starts",
                ));
            }
            state.cancel_requested = true;
            state.child.clone()
        };
        match child {
            Some(child) => child.cancel(),
            None => Ok(()),
        }
    }

    fn join(&self) -> Result<(), String> {
        let worker = {
            let mut state = self
                .completion
                .state
                .lock()
                .map_err(|_| "Runtime execution join state is unavailable".to_owned())?;
            loop {
                match &mut *state {
                    WorkerJoinState::Pending => {
                        state = self.completion.changed.wait(state).map_err(|_| {
                            "Runtime execution join state is unavailable".to_owned()
                        })?;
                    }
                    WorkerJoinState::Ready(worker) => {
                        let worker = worker
                            .take()
                            .expect("ready Runtime execution owns its thread");
                        *state = WorkerJoinState::Joining;
                        self.completion.changed.notify_all();
                        break worker;
                    }
                    WorkerJoinState::Joining => {
                        state = self.completion.changed.wait(state).map_err(|_| {
                            "Runtime execution join state is unavailable".to_owned()
                        })?;
                    }
                    WorkerJoinState::Completed(result) => return result.clone(),
                }
            }
        };

        let result = worker
            .join()
            .map_err(|_| "Runtime execution thread panicked".to_owned())
            .and_then(|result| result);
        let mut state = self
            .completion
            .state
            .lock()
            .map_err(|_| "Runtime execution join state is unavailable".to_owned())?;
        *state = WorkerJoinState::Completed(result.clone());
        self.completion.changed.notify_all();
        result
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum CancellationPolicy {
    Deferred,
    Unsupported,
}

#[derive(Default)]
struct ChildState {
    child: Option<Arc<dyn ProcessControl>>,
    cancel_requested: bool,
    finished: bool,
}

struct WorkerCompletion {
    state: Mutex<WorkerJoinState>,
    changed: Condvar,
}

enum WorkerJoinState {
    Pending,
    Ready(Option<JoinHandle<Result<(), String>>>),
    Joining,
    Completed(Result<(), String>),
}
