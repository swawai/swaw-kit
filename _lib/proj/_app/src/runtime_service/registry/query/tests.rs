use std::ffi::OsString;
use std::io;
use std::sync::atomic::{AtomicBool, Ordering};

use super::*;
use crate::runtime_service::execution::RuntimeExecutionSpec;
use crate::runtime_service::registry::RunRegistry;

#[test]
fn returns_clean_stdout_and_exit_code() {
    let output = execute_query(
        ImmediateRunner {
            stdout: "{\"protocol\":\"fixture/v1\"}",
            stderr: "",
            progress: false,
            outcome: Some(ProcessOutcome::Exited(0)),
            canceled: Arc::new(AtomicBool::new(false)),
        },
        Duration::from_secs(1),
        1024,
    )
    .expect("clean query result");

    assert_eq!(output.stdout, "{\"protocol\":\"fixture/v1\"}");
    assert_eq!(output.exit_code, 0);
}

#[test]
fn rejects_stderr_progress_and_failed_outcomes() {
    for runner in [
        ImmediateRunner {
            stdout: "{}",
            stderr: "warning",
            progress: false,
            outcome: Some(ProcessOutcome::Exited(0)),
            canceled: Arc::new(AtomicBool::new(false)),
        },
        ImmediateRunner {
            stdout: "{}",
            stderr: "",
            progress: true,
            outcome: Some(ProcessOutcome::Exited(0)),
            canceled: Arc::new(AtomicBool::new(false)),
        },
        ImmediateRunner {
            stdout: "{}",
            stderr: "",
            progress: false,
            outcome: Some(ProcessOutcome::Failed("worker failed".to_owned())),
            canceled: Arc::new(AtomicBool::new(false)),
        },
    ] {
        assert!(execute_query(runner, Duration::from_secs(1), 1024).is_err());
    }
}

#[test]
fn overflow_and_timeout_cancel_and_join_the_query() {
    let overflow_canceled = Arc::new(AtomicBool::new(false));
    let overflow_joined = Arc::new(AtomicBool::new(false));
    let error = rejected(execute_query_with_join(
        ImmediateRunner {
            stdout: "too large",
            stderr: "",
            progress: false,
            outcome: None,
            canceled: Arc::clone(&overflow_canceled),
        },
        Duration::from_secs(1),
        2,
        Arc::clone(&overflow_joined),
    ));
    assert!(error.contains("byte limit"));
    assert!(overflow_canceled.load(Ordering::Acquire));
    assert!(overflow_joined.load(Ordering::Acquire));

    let timeout_canceled = Arc::new(AtomicBool::new(false));
    let timeout_joined = Arc::new(AtomicBool::new(false));
    let error = rejected(execute_query_with_join(
        ImmediateRunner {
            stdout: "",
            stderr: "",
            progress: false,
            outcome: None,
            canceled: Arc::clone(&timeout_canceled),
        },
        Duration::from_millis(1),
        1024,
        Arc::clone(&timeout_joined),
    ));
    assert!(error.contains("timed out"));
    assert!(timeout_canceled.load(Ordering::Acquire));
    assert!(timeout_joined.load(Ordering::Acquire));
}

#[test]
fn shutdown_only_joins_a_non_cancelable_core_query() {
    let canceled = Arc::new(AtomicBool::new(false));
    let joined = Arc::new(AtomicBool::new(false));
    let operation = QueryOperation::new(false);
    let observer: Arc<dyn ProcessObserver> = operation.observer.clone();
    operation
        .control
        .attach(Arc::new(ImmediateControl {
            observer,
            canceled: Arc::clone(&canceled),
            joined: Arc::clone(&joined),
        }))
        .expect("attach Core fixture control");

    operation
        .begin_shutdown_cancel()
        .expect("begin Core shutdown");
    operation
        .finish_shutdown_cancel()
        .expect("finish Core shutdown");
    operation.join_control().expect("join Core query");

    assert!(!canceled.load(Ordering::Acquire));
    assert!(joined.load(Ordering::Acquire));
}

struct ImmediateRunner {
    stdout: &'static str,
    stderr: &'static str,
    progress: bool,
    outcome: Option<ProcessOutcome>,
    canceled: Arc<AtomicBool>,
}

struct ImmediateControl {
    observer: Arc<dyn ProcessObserver>,
    canceled: Arc<AtomicBool>,
    joined: Arc<AtomicBool>,
}

impl crate::process_runner::ProcessControl for ImmediateControl {
    fn cancel(&self) -> io::Result<()> {
        if !self.canceled.swap(true, Ordering::AcqRel) {
            self.observer.completed(ProcessOutcome::Exited(1223));
        }
        Ok(())
    }

    fn join(&self) -> Result<(), String> {
        self.joined.store(true, Ordering::Release);
        Ok(())
    }
}

struct JoinTrackingRunner {
    inner: ImmediateRunner,
    joined: Arc<AtomicBool>,
}

impl RuntimeExecutionRunner for JoinTrackingRunner {
    fn start(
        &self,
        _execution: PreparedExecution,
        observer: Arc<dyn ProcessObserver>,
    ) -> io::Result<Arc<dyn crate::process_runner::ProcessControl>> {
        observer.output(ProcessOutputStream::Stdout, self.inner.stdout.to_owned());
        observer.output(ProcessOutputStream::Stderr, self.inner.stderr.to_owned());
        if self.inner.progress {
            observer.progress(CommandProgress {
                id: "fixture".to_owned(),
                state: crate::command_event::CommandProgressState::Running,
                current: None,
                total: None,
                unit: crate::command_event::CommandProgressUnit::Items,
                message: "fixture progress".to_owned(),
            });
        }
        if let Some(outcome) = self.inner.outcome.clone() {
            observer.completed(outcome);
        }
        Ok(Arc::new(ImmediateControl {
            observer,
            canceled: Arc::clone(&self.inner.canceled),
            joined: Arc::clone(&self.joined),
        }))
    }
}

fn execute_query(
    runner: ImmediateRunner,
    timeout: Duration,
    output_limit: usize,
) -> Result<RuntimeQueryOutput, String> {
    execute_query_with_join(
        runner,
        timeout,
        output_limit,
        Arc::new(AtomicBool::new(false)),
    )
}

fn execute_query_with_join(
    runner: ImmediateRunner,
    timeout: Duration,
    output_limit: usize,
    joined: Arc<AtomicBool>,
) -> Result<RuntimeQueryOutput, String> {
    let runner: Arc<dyn RuntimeExecutionRunner> = Arc::new(JoinTrackingRunner {
        inner: runner,
        joined,
    });
    let registry = RunRegistry::new(Arc::clone(&runner));
    let registration = registry
        .inner
        .register_query(true)
        .expect("register fixture query");
    run_query_with(runner, execution(), registration, timeout, output_limit)
}

fn execution() -> PreparedExecution {
    PreparedExecution::cancelable_fixture(RuntimeExecutionSpec::new(
        ".fixture",
        vec![OsString::from(".fixture")],
        ".",
    ))
}

fn rejected(result: Result<RuntimeQueryOutput, String>) -> String {
    match result {
        Ok(_) => panic!("fixture query must be rejected"),
        Err(error) => error,
    }
}
