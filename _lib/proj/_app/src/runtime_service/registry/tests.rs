use std::ffi::OsString;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{
    Arc, Mutex, Weak,
    atomic::{AtomicBool, AtomicU64, Ordering},
    mpsc,
};
use std::thread;
use std::time::Duration;

use super::*;
use crate::process_runner::{ProcessControl, ProcessObserver, ProcessOutcome, ProcessOutputStream};
use crate::run_journal::{RunJournalSource, StartRunJournal};
use crate::runtime_service::execution::RuntimeExecutionSpec;

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

struct RunFixture {
    root: PathBuf,
    run: Option<Arc<CommandRun>>,
}

impl RunFixture {
    fn new() -> Self {
        let root = fixture_root("run");
        let journal = RunJournal::start(journal_request(&root)).expect("start fixture journal");
        let id = journal.id().expect("fixture journal id");
        Self {
            root,
            run: Some(Arc::new(CommandRun::new(
                id,
                ".fixture".to_owned(),
                journal,
                true,
            ))),
        }
    }

    fn run(&self) -> &Arc<CommandRun> {
        self.run.as_ref().expect("fixture command run")
    }

    fn drop_run(&mut self) {
        drop(self.run.take());
    }
}

impl Drop for RunFixture {
    fn drop(&mut self) {
        self.drop_run();
        let _ = fs::remove_dir_all(&self.root);
    }
}

struct FailingControl;

impl ProcessControl for FailingControl {
    fn cancel(&self) -> io::Result<()> {
        Err(io::Error::other("fixture cancellation failed"))
    }

    fn join(&self) -> Result<(), String> {
        Ok(())
    }
}

struct DropAwareControl(Arc<AtomicBool>);

impl ProcessControl for DropAwareControl {
    fn cancel(&self) -> io::Result<()> {
        Ok(())
    }

    fn join(&self) -> Result<(), String> {
        Ok(())
    }
}

impl Drop for DropAwareControl {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Release);
    }
}

#[test]
fn failed_cancellation_restores_a_running_state() {
    let fixture = RunFixture::new();
    let run = fixture.run();
    run.attach_control(Arc::new(FailingControl))
        .expect("attach fixture control");

    let error = run.cancel().expect_err("fixture cancellation must fail");

    assert!(error.to_string().contains("fixture cancellation failed"));
    assert_eq!(
        run.document(0).expect("command run document").state,
        CommandRunState::Running
    );
}

#[test]
fn bounds_small_output_chunks_by_event_count() {
    let fixture = RunFixture::new();
    let run = fixture.run();

    for _ in 0..=MAX_OUTPUT_EVENTS {
        run.append(ProcessOutputStream::Stdout, "x".to_owned());
    }

    let document = run.document(0).expect("command run document");
    assert!(document.truncated);
    assert_eq!(document.events.len(), MAX_OUTPUT_EVENTS);
    assert_eq!(document.events[0].sequence, 2);
    assert_eq!(document.next_cursor, (MAX_OUTPUT_EVENTS + 1) as u64);
}

#[test]
fn observer_does_not_keep_a_dropped_run_control_alive() {
    let dropped = Arc::new(AtomicBool::new(false));
    let mut fixture = RunFixture::new();
    let run = Arc::clone(fixture.run());
    run.attach_control(Arc::new(DropAwareControl(Arc::clone(&dropped))))
        .expect("attach drop-aware control");
    let observer = RunObserver {
        run: Arc::downgrade(&run),
        registry: Weak::new(),
    };

    drop(run);
    fixture.drop_run();

    assert!(dropped.load(Ordering::Acquire));
    observer.output(ProcessOutputStream::Stdout, "ignored".to_owned());
    observer.completed(ProcessOutcome::Exited(0));
}

#[test]
fn query_slots_share_the_run_capacity_limit() {
    let registry = RunRegistry::new(Arc::new(FailingRunner));
    let slots = (0..MAX_ACTIVE_OPERATIONS)
        .map(|_| {
            registry
                .inner
                .register_query(true)
                .expect("reserve query slot")
        })
        .collect::<Vec<_>>();

    let error = match registry.inner.register_query(true) {
        Ok(_) => panic!("capacity must be enforced"),
        Err(error) => error,
    };
    assert!(matches!(error, RuntimeServiceError::Capacity));
    drop(slots);
    assert_eq!(
        registry.inner.state.lock().expect("registry state").active,
        0
    );
}

#[test]
fn infrastructure_start_error_fails_the_journal_and_releases_capacity() {
    let root = fixture_root("start-error");
    let registry = RunRegistry::new(Arc::new(FailingRunner));

    let error = registry
        .start(execution(), journal_request(&root))
        .expect_err("fixture execution start must fail");

    assert!(matches!(error, RuntimeServiceError::Start(_)));
    let state = registry.inner.state.lock().expect("registry state");
    assert_eq!(state.active, 0);
    assert!(state.runs.is_empty());
    drop(state);
    let stored = only_journal_state(&root);
    assert_eq!(stored["status"], "failed");
    assert!(
        stored["error"]
            .as_str()
            .is_some_and(|error| error.contains("fixture start failed"))
    );
    let _ = fs::remove_dir_all(root);
}

#[test]
fn shutdown_cancels_a_run_whose_control_attaches_after_shutdown_starts() {
    let root = fixture_root("attach-race");
    let (runner, entered, release, canceled, joined) = blocking_runner();
    let registry = RunRegistry::new(runner);
    let start_registry = registry.clone();
    let start_root = root.clone();
    let start =
        thread::spawn(move || start_registry.start(execution(), journal_request(&start_root)));
    entered
        .recv_timeout(Duration::from_secs(2))
        .expect("runner must enter start");

    let shutdown_registry = registry.clone();
    let (shutdown_done_tx, shutdown_done_rx) = mpsc::channel();
    let shutdown = thread::spawn(move || {
        shutdown_done_tx.send(shutdown_registry.shutdown()).unwrap();
    });
    assert!(
        shutdown_done_rx
            .recv_timeout(Duration::from_millis(30))
            .is_err()
    );

    release.send(()).expect("release runner start");
    shutdown_done_rx
        .recv_timeout(Duration::from_secs(2))
        .expect("shutdown must finish")
        .expect("shutdown result");
    shutdown.join().expect("shutdown thread");
    let document = start.join().expect("start thread").expect("start result");

    assert!(canceled.load(Ordering::Acquire));
    assert!(joined.load(Ordering::Acquire));
    assert_eq!(document.state, CommandRunState::Canceled);
    assert_eq!(
        registry.inner.state.lock().expect("registry state").active,
        0
    );
    let _ = fs::remove_dir_all(root);
}

#[test]
fn shutdown_cancels_and_joins_an_in_flight_query() {
    let (runner, entered, release, canceled, joined) = blocking_runner();
    let registry = RunRegistry::new(runner);
    let query_registry = registry.clone();
    let query = thread::spawn(move || query_registry.query(execution()));
    entered
        .recv_timeout(Duration::from_secs(2))
        .expect("query runner must enter start");

    let shutdown_registry = registry.clone();
    let shutdown = thread::spawn(move || shutdown_registry.shutdown());
    release.send(()).expect("release query start");

    shutdown
        .join()
        .expect("shutdown thread")
        .expect("shutdown result");
    let query_error = match query.join().expect("query thread") {
        Ok(_) => panic!("shutdown must reject the in-flight query"),
        Err(error) => error,
    };
    assert!(
        query_error
            .to_string()
            .contains("runtime service is shutting down")
    );
    assert!(canceled.load(Ordering::Acquire));
    assert!(joined.load(Ordering::Acquire));
    assert_eq!(
        registry.inner.state.lock().expect("registry state").active,
        0
    );
}

struct FailingRunner;

impl RuntimeExecutionRunner for FailingRunner {
    fn start(
        &self,
        _execution: PreparedExecution,
        _observer: Arc<dyn ProcessObserver>,
    ) -> io::Result<Arc<dyn ProcessControl>> {
        Err(io::Error::other("fixture start failed"))
    }
}

struct BlockingRunner {
    entered: mpsc::Sender<()>,
    release: Mutex<mpsc::Receiver<()>>,
    canceled: Arc<AtomicBool>,
    joined: Arc<AtomicBool>,
}

impl RuntimeExecutionRunner for BlockingRunner {
    fn start(
        &self,
        _execution: PreparedExecution,
        observer: Arc<dyn ProcessObserver>,
    ) -> io::Result<Arc<dyn ProcessControl>> {
        self.entered.send(()).expect("signal entered start");
        self.release
            .lock()
            .expect("release receiver")
            .recv()
            .expect("wait for start release");
        Ok(Arc::new(CompletingControl {
            observer,
            canceled: Arc::clone(&self.canceled),
            joined: Arc::clone(&self.joined),
        }))
    }
}

struct CompletingControl {
    observer: Arc<dyn ProcessObserver>,
    canceled: Arc<AtomicBool>,
    joined: Arc<AtomicBool>,
}

impl ProcessControl for CompletingControl {
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

type BlockingRunnerFixture = (
    Arc<dyn RuntimeExecutionRunner>,
    mpsc::Receiver<()>,
    mpsc::Sender<()>,
    Arc<AtomicBool>,
    Arc<AtomicBool>,
);

fn blocking_runner() -> BlockingRunnerFixture {
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let canceled = Arc::new(AtomicBool::new(false));
    let joined = Arc::new(AtomicBool::new(false));
    (
        Arc::new(BlockingRunner {
            entered: entered_tx,
            release: Mutex::new(release_rx),
            canceled: Arc::clone(&canceled),
            joined: Arc::clone(&joined),
        }),
        entered_rx,
        release_tx,
        canceled,
        joined,
    )
}

fn execution() -> PreparedExecution {
    PreparedExecution::cancelable_fixture(RuntimeExecutionSpec::new(
        ".fixture",
        vec![OsString::from(".fixture")],
        ".",
    ))
}

fn journal_request(root: &Path) -> StartRunJournal {
    StartRunJournal {
        module_data_root: root.to_path_buf(),
        address: ".fixture".to_owned(),
        source: RunJournalSource::Web,
        argument_count: 0,
    }
}

fn fixture_root(label: &str) -> PathBuf {
    let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
    let workspace = Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(3)
        .expect("workspace root");
    workspace
        .join("data/proj_cache/tests/run-registry")
        .join(format!("{}-{sequence}-{label}", std::process::id()))
}

fn only_journal_state(root: &Path) -> serde_json::Value {
    let runs = root.join(crate::run_journal::JOURNAL_DIRECTORY_NAME);
    let run = fs::read_dir(runs)
        .expect("journal directory")
        .filter_map(Result::ok)
        .find(|entry| {
            entry
                .file_name()
                .to_string_lossy()
                .chars()
                .all(|c| c != '.')
        })
        .expect("published journal");
    serde_json::from_slice(
        &fs::read(run.path().join(crate::run_journal::JOURNAL_STATE_FILE_NAME))
            .expect("journal state"),
    )
    .expect("journal state JSON")
}
