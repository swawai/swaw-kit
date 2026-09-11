use std::env;
use std::io;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Barrier, mpsc};
use std::thread;
use std::time::Duration;

use windows_sys::Win32::System::Threading::CREATE_NO_WINDOW;

use super::control::NativeProcessControl;
use super::monitor::{MonitorSpawnFailure, MonitorSpawner, MonitorTask, merged_cleanup_error};
use super::*;

#[test]
fn process_labels_are_bounded_and_surrogate_pairs_are_not_split() {
    let target = "a".repeat(MAX_PROCESS_LABEL_UTF16);
    let label = ProcessLabel::new("Entry Launcher", OsStr::new(&target));
    assert!(label.start_description().encode_utf16().count() <= MAX_PROCESS_LABEL_UTF16);

    // The ellipsis leaves five UTF-16 units for content. The crab needs two
    // units and starts with only one remaining, so it must be omitted whole.
    assert_eq!(bounded_utf16("aaaa\u{1f980}z", 6), "aaaa\u{2026}");
}

#[test]
fn monitor_spawn_failure_reaps_the_process_without_observer_callbacks() {
    let observer = Arc::new(CountingObserver::default());
    let observer_boundary: Arc<dyn ProcessObserver> = observer.clone();
    let command = Command::new(command_executable());
    let result = NativeProcessRunner.start_with_monitor_spawner(
        ProcessLaunch::new(command, "Entry Launcher", CREATE_NO_WINDOW),
        observer_boundary,
        &FailingMonitorSpawner,
    );

    let error = match result {
        Ok(_) => panic!("monitor failure unexpectedly started a process"),
        Err(error) => error,
    };
    assert_eq!(error.to_string(), "fixture monitor spawn failed");
    assert_eq!(observer.callbacks.load(Ordering::Acquire), 0);
}

#[test]
fn monitor_spawn_failure_preserves_cleanup_diagnostics() {
    let error = merged_cleanup_error(
        io::Error::other("fixture monitor spawn failed"),
        vec!["fixture reader cleanup failed".to_owned()],
    );

    assert_eq!(
        error.to_string(),
        "fixture monitor spawn failed; additionally, fixture reader cleanup failed"
    );
}

#[test]
fn process_control_join_caches_the_monitor_result() {
    let monitor = thread::spawn(|| panic!("fixture monitor panic"));
    let control = NativeProcessControl::new(
        Arc::new(OwnedProcessJob::create().expect("test process Job")),
        monitor,
    );

    let first = control.join();
    let second = control.join();

    assert_eq!(first, Err("command process monitor panicked".to_owned()));
    assert_eq!(second, first);
}

#[test]
fn concurrent_process_control_joiners_wait_for_one_completion() {
    let (release_tx, release_rx) = mpsc::channel();
    let monitor = thread::spawn(move || release_rx.recv().expect("monitor release"));
    let control = Arc::new(NativeProcessControl::new(
        Arc::new(OwnedProcessJob::create().expect("test process Job")),
        monitor,
    ));
    let (result_tx, result_rx) = mpsc::channel();

    let first_control = Arc::clone(&control);
    let first_tx = result_tx.clone();
    let first = thread::spawn(move || first_tx.send(first_control.join()).unwrap());
    control.wait_until_joining();

    let entered = Arc::new(Barrier::new(2));
    let second_entered = Arc::clone(&entered);
    let second_control = Arc::clone(&control);
    let second = thread::spawn(move || {
        second_entered.wait();
        result_tx.send(second_control.join()).unwrap();
    });
    entered.wait();
    assert!(result_rx.recv_timeout(Duration::from_millis(30)).is_err());

    release_tx.send(()).unwrap();
    let mut results = [result_rx.recv().unwrap(), result_rx.recv().unwrap()];
    first.join().unwrap();
    second.join().unwrap();
    results.sort_by_key(Result::is_err);
    assert_eq!(results, [Ok(()), Ok(())]);
}

#[derive(Default)]
struct CountingObserver {
    callbacks: AtomicUsize,
}

impl ProcessObserver for CountingObserver {
    fn output(&self, _stream: ProcessOutputStream, _text: String) {
        self.callbacks.fetch_add(1, Ordering::AcqRel);
    }

    fn progress(&self, _progress: CommandProgress) {
        self.callbacks.fetch_add(1, Ordering::AcqRel);
    }

    fn completed(&self, _outcome: ProcessOutcome) {
        self.callbacks.fetch_add(1, Ordering::AcqRel);
    }
}

struct FailingMonitorSpawner;

impl MonitorSpawner for FailingMonitorSpawner {
    fn spawn(&self, task: MonitorTask) -> Result<thread::JoinHandle<()>, MonitorSpawnFailure> {
        Err(MonitorSpawnFailure::new(
            io::Error::other("fixture monitor spawn failed"),
            task,
        ))
    }
}

fn command_executable() -> PathBuf {
    PathBuf::from(env::var_os("SystemRoot").expect("SystemRoot")).join("System32/cmd.exe")
}
