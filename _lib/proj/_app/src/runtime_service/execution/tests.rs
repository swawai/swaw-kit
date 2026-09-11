use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Barrier, mpsc};
use std::thread;
use std::time::Duration;

use super::*;
use support::*;

mod support;

#[test]
fn metadata_stays_logical_and_transport_neutral() {
    let spec = execution_spec(".demo", ["first", "second"]);
    let execution = PreparedExecution::fixture(spec.clone());

    assert_eq!(execution.address(), ".demo");
    assert_eq!(execution.argv(), spec.argv());
    assert_eq!(execution.arguments(), spec.arguments());
    assert_eq!(execution.working_directory(), spec.working_directory());
    assert_eq!(spec.argument_count(), 2);
    assert!(!execution.cancelable());
    assert!(PreparedExecution::cancelable_fixture(spec).cancelable());
}

#[test]
fn core_success_and_error_are_command_outcomes() {
    let success = Arc::new(RecordingObserver::default());
    let control = runner(Arc::new(UnusedProcessRunner))
        .start(
            PreparedExecution::core_fixture(
                execution_spec(".help", []),
                FixedCoreTask(Ok(CoreCommandOutcome::with_exit_code(7, "answer\n"))),
            ),
            success.clone(),
        )
        .unwrap();
    control.join().unwrap();
    assert_eq!(
        success.events(),
        vec![
            ObserverEvent::Output(ProcessOutputStream::Stdout, "answer\n".to_owned()),
            ObserverEvent::Completed(ProcessOutcome::Exited(7)),
        ]
    );

    let failure = Arc::new(RecordingObserver::default());
    let control = runner(Arc::new(UnusedProcessRunner))
        .start(
            PreparedExecution::core_fixture(
                execution_spec(".help", []),
                FixedCoreTask(Err("bad arguments".to_owned())),
            ),
            failure.clone(),
        )
        .unwrap();
    control.join().unwrap();
    assert_eq!(
        failure.events(),
        vec![
            ObserverEvent::Output(
                ProcessOutputStream::Stderr,
                "[ERROR] bad arguments\n".to_owned(),
            ),
            ObserverEvent::Completed(ProcessOutcome::Exited(1)),
        ]
    );
}

#[test]
fn process_materialization_and_start_errors_are_command_outcomes() {
    let starts = Arc::new(AtomicUsize::new(0));
    let materialize_observer = Arc::new(RecordingObserver::default());
    let control = runner(Arc::new(CountingUnusedRunner {
        starts: Arc::clone(&starts),
    }))
    .start(
        PreparedExecution::process_fixture(
            execution_spec("demo/run", []),
            FailingProcessTask("adapter artifact is unavailable"),
        ),
        materialize_observer.clone(),
    )
    .unwrap();
    control.join().unwrap();
    assert_eq!(starts.load(Ordering::Acquire), 0);
    assert_command_error(
        &materialize_observer,
        "[ERROR] adapter artifact is unavailable\n",
    );

    let start_observer = Arc::new(RecordingObserver::default());
    let control = runner(Arc::new(FailingProcessRunner))
        .start(
            PreparedExecution::process_fixture(execution_spec("demo/run", []), FixedProcessTask),
            start_observer.clone(),
        )
        .unwrap();
    control.join().unwrap();
    assert_command_error(&start_observer, "[ERROR] fixture process start failed\n");
}

#[test]
fn process_cancel_requested_before_child_attach_is_forwarded() {
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let canceled = Arc::new(AtomicBool::new(false));
    let observer = Arc::new(RecordingObserver::default());
    let control = runner(Arc::new(ControllableProcessRunner {
        canceled: Arc::clone(&canceled),
    }))
    .start(
        PreparedExecution::process_fixture(
            execution_spec("demo/run", []),
            BlockingProcessTask {
                entered: entered_tx,
                release: release_rx,
            },
        ),
        observer.clone(),
    )
    .unwrap();

    entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    control.cancel().unwrap();
    assert!(!canceled.load(Ordering::Acquire));
    release_tx.send(()).unwrap();
    control.join().unwrap();

    assert!(canceled.load(Ordering::Acquire));
    assert_eq!(
        observer.events(),
        vec![ObserverEvent::Completed(ProcessOutcome::Exited(1223))]
    );
}

#[test]
fn running_core_rejects_cancel_and_preserves_its_real_outcome() {
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let observer = Arc::new(RecordingObserver::default());
    let control = runner(Arc::new(UnusedProcessRunner))
        .start(
            PreparedExecution::core_fixture(
                execution_spec(".entry/language", ["en"]),
                BlockingCoreTask {
                    entered: entered_tx,
                    release: release_rx,
                },
            ),
            observer.clone(),
        )
        .unwrap();

    entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(
        control.cancel().unwrap_err().to_string(),
        "an in-process Core command cannot be canceled after it starts"
    );
    release_tx.send(()).unwrap();
    control.join().unwrap();
    control.cancel().unwrap();
    assert_eq!(
        observer.events(),
        vec![ObserverEvent::Completed(ProcessOutcome::Exited(0))]
    );
}

#[test]
fn concurrent_and_repeated_joiners_share_one_result() {
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let control = runner(Arc::new(UnusedProcessRunner))
        .start(
            PreparedExecution::core_fixture(
                execution_spec(".help", []),
                BlockingCoreTask {
                    entered: entered_tx,
                    release: release_rx,
                },
            ),
            Arc::new(RecordingObserver::default()),
        )
        .unwrap();
    entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    let barrier = Arc::new(Barrier::new(3));
    let (result_tx, result_rx) = mpsc::channel();
    let mut joiners = Vec::new();
    for _ in 0..2 {
        let control = Arc::clone(&control);
        let barrier = Arc::clone(&barrier);
        let result_tx = result_tx.clone();
        joiners.push(thread::spawn(move || {
            barrier.wait();
            result_tx.send(control.join()).unwrap();
        }));
    }
    barrier.wait();
    assert!(result_rx.recv_timeout(Duration::from_millis(30)).is_err());
    release_tx.send(()).unwrap();

    assert_eq!(result_rx.recv().unwrap(), Ok(()));
    assert_eq!(result_rx.recv().unwrap(), Ok(()));
    for joiner in joiners {
        joiner.join().unwrap();
    }
    assert_eq!(control.join(), Ok(()));
}

#[test]
fn execution_failure_and_panic_always_complete_the_observer() {
    let panic_observer = Arc::new(RecordingObserver::default());
    let control = runner(Arc::new(UnusedProcessRunner))
        .start(
            PreparedExecution::core_fixture(execution_spec(".help", []), PanickingCoreTask),
            panic_observer.clone(),
        )
        .unwrap();
    let panic_error = "Runtime execution thread panicked: fixture execution panic";
    assert_eq!(control.join(), Err(panic_error.to_owned()));
    assert_eq!(
        panic_observer.events(),
        vec![ObserverEvent::Completed(ProcessOutcome::Failed(
            panic_error.to_owned()
        ))]
    );

    let join_observer = Arc::new(RecordingObserver::default());
    let control = runner(Arc::new(JoinFailingProcessRunner))
        .start(
            PreparedExecution::process_fixture(execution_spec("demo/run", []), FixedProcessTask),
            join_observer.clone(),
        )
        .unwrap();
    assert_eq!(
        control.join(),
        Err("fixture process join failed".to_owned())
    );
    assert_eq!(
        join_observer.events(),
        vec![ObserverEvent::Completed(ProcessOutcome::Failed(
            "fixture process join failed".to_owned()
        ))]
    );
}

#[test]
fn execution_thread_start_failure_has_no_callbacks() {
    let observer = Arc::new(RecordingObserver::default());
    let runtime = NativeRuntimeExecutionRunner::with_spawner(
        Arc::new(UnusedProcessRunner),
        Arc::new(FailingExecutionThreadSpawner),
    );
    let result = runtime.start(
        PreparedExecution::fixture(execution_spec(".help", [])),
        observer.clone(),
    );

    let error = match result {
        Ok(_) => panic!("execution unexpectedly started"),
        Err(error) => error,
    };
    assert_eq!(error.to_string(), "fixture execution thread start failed");
    assert!(observer.events().is_empty());
}
