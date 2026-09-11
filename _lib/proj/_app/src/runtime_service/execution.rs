mod control;
mod prepared;

use std::io;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::{self, JoinHandle};

use crate::core_command::CoreCommandOutcome;
use crate::process_runner::{
    NativeProcessRunner, ProcessControl, ProcessObserver, ProcessOutcome, ProcessOutputStream,
    ProcessRunner,
};

use control::{CancellationPolicy, DeferredExecutionControl};
use prepared::PreparedExecutionKind;
#[cfg(test)]
use prepared::{CoreTask, ProcessTask};
pub(crate) use prepared::{PreparedExecution, RuntimeExecutionSpec};

pub(crate) trait RuntimeExecutionRunner: Send + Sync {
    /// Starts one already-journaled execution.
    ///
    /// Only failure to create the Runtime execution thread is returned here.
    /// Command preparation, command-process start, and Core handler failures
    /// are ordinary command results reported through `observer`.
    fn start(
        &self,
        execution: PreparedExecution,
        observer: Arc<dyn ProcessObserver>,
    ) -> io::Result<Arc<dyn ProcessControl>>;
}

pub(crate) struct NativeRuntimeExecutionRunner {
    processes: Arc<dyn ProcessRunner>,
    threads: Arc<dyn ExecutionThreadSpawner>,
}

impl NativeRuntimeExecutionRunner {
    pub(crate) fn new(processes: Arc<dyn ProcessRunner>) -> Self {
        Self {
            processes,
            threads: Arc::new(NativeExecutionThreadSpawner),
        }
    }

    #[cfg(test)]
    fn with_spawner(
        processes: Arc<dyn ProcessRunner>,
        threads: Arc<dyn ExecutionThreadSpawner>,
    ) -> Self {
        Self { processes, threads }
    }
}

impl Default for NativeRuntimeExecutionRunner {
    fn default() -> Self {
        Self::new(Arc::new(NativeProcessRunner))
    }
}

impl RuntimeExecutionRunner for NativeRuntimeExecutionRunner {
    fn start(
        &self,
        execution: PreparedExecution,
        observer: Arc<dyn ProcessObserver>,
    ) -> io::Result<Arc<dyn ProcessControl>> {
        let cancellation = match &execution.kind {
            PreparedExecutionKind::Core(_) => CancellationPolicy::Unsupported,
            PreparedExecutionKind::Process(_) => CancellationPolicy::Deferred,
        };
        let control = Arc::new(DeferredExecutionControl::new(cancellation));
        let task_control = Arc::clone(&control);
        let failure_control = Arc::clone(&control);
        let processes = Arc::clone(&self.processes);
        let observer: Arc<dyn ProcessObserver> = Arc::new(CompletionObserver::new(observer));
        let failure_observer = Arc::clone(&observer);
        let worker = self.threads.spawn(Box::new(move || {
            let result = catch_unwind(AssertUnwindSafe(|| {
                run_execution(execution, processes, observer, task_control)
            }));
            match result {
                Ok(Ok(())) => Ok(()),
                Ok(Err(error)) => {
                    failure_control.abort_child();
                    failure_observer.completed(ProcessOutcome::Failed(error.clone()));
                    Err(error)
                }
                Err(payload) => {
                    failure_control.abort_child();
                    let error = panic_message(payload);
                    failure_observer.completed(ProcessOutcome::Failed(error.clone()));
                    Err(error)
                }
            }
        }))?;
        control.attach_worker(worker);
        Ok(control)
    }
}

struct CompletionObserver {
    inner: Arc<dyn ProcessObserver>,
    completed: AtomicBool,
}

impl CompletionObserver {
    fn new(inner: Arc<dyn ProcessObserver>) -> Self {
        Self {
            inner,
            completed: AtomicBool::new(false),
        }
    }
}

impl ProcessObserver for CompletionObserver {
    fn output(&self, stream: ProcessOutputStream, text: String) {
        if !self.completed.load(Ordering::Acquire) {
            self.inner.output(stream, text);
        }
    }

    fn progress(&self, progress: crate::command_event::CommandProgress) {
        if !self.completed.load(Ordering::Acquire) {
            self.inner.progress(progress);
        }
    }

    fn completed(&self, outcome: ProcessOutcome) {
        if self
            .completed
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
        {
            self.inner.completed(outcome);
        }
    }
}

fn run_execution(
    execution: PreparedExecution,
    processes: Arc<dyn ProcessRunner>,
    observer: Arc<dyn ProcessObserver>,
    control: Arc<DeferredExecutionControl>,
) -> Result<(), String> {
    match execution.kind {
        PreparedExecutionKind::Core(task) => {
            match task.execute() {
                Ok(outcome) => complete_core(&observer, outcome),
                Err(error) => complete_command_error(&observer, &error),
            }
            control.finish_without_child();
            Ok(())
        }
        PreparedExecutionKind::Process(task) => {
            let launch = match task.materialize() {
                Ok(launch) => launch,
                Err(error) => {
                    complete_command_error(&observer, &error);
                    control.finish_without_child();
                    return Ok(());
                }
            };
            let child = match processes.start(launch, Arc::clone(&observer)) {
                Ok(child) => child,
                Err(error) => {
                    complete_command_error(&observer, &error.to_string());
                    control.finish_without_child();
                    return Ok(());
                }
            };
            let pending_cancel = control.attach_child(Arc::clone(&child));
            let cancel = pending_cancel.then(|| child.cancel()).transpose();
            let join = child.join();
            control.finish_child();
            cancel.map_err(|error| format!("cannot cancel the command process: {error}"))?;
            join
        }
    }
}

fn complete_core(observer: &Arc<dyn ProcessObserver>, outcome: CoreCommandOutcome) {
    if !outcome.stdout.is_empty() {
        observer.output(ProcessOutputStream::Stdout, outcome.stdout);
    }
    observer.completed(ProcessOutcome::Exited(outcome.exit_code));
}

fn complete_command_error(observer: &Arc<dyn ProcessObserver>, error: &str) {
    observer.output(ProcessOutputStream::Stderr, format!("[ERROR] {error}\n"));
    observer.completed(ProcessOutcome::Exited(1));
}

fn panic_message(payload: Box<dyn std::any::Any + Send>) -> String {
    let detail = payload
        .downcast_ref::<&str>()
        .copied()
        .or_else(|| payload.downcast_ref::<String>().map(String::as_str));
    match detail {
        Some(detail) => format!("Runtime execution thread panicked: {detail}"),
        None => "Runtime execution thread panicked".to_owned(),
    }
}

type ExecutionTask = Box<dyn FnOnce() -> Result<(), String> + Send + 'static>;

trait ExecutionThreadSpawner: Send + Sync {
    fn spawn(&self, task: ExecutionTask) -> io::Result<JoinHandle<Result<(), String>>>;
}

struct NativeExecutionThreadSpawner;

impl ExecutionThreadSpawner for NativeExecutionThreadSpawner {
    fn spawn(&self, task: ExecutionTask) -> io::Result<JoinHandle<Result<(), String>>> {
        thread::Builder::new()
            .name("swawkit-runtime-execution".to_owned())
            .spawn(task)
    }
}

#[cfg(test)]
mod tests;
