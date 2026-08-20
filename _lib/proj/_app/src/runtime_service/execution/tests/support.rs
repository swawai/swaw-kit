use std::ffi::OsString;
use std::io;
use std::process::Command;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;

use crate::command_event::CommandProgress;
use crate::process_runner::ProcessLaunch;

use super::super::*;

pub(super) fn runner(processes: Arc<dyn ProcessRunner>) -> NativeRuntimeExecutionRunner {
    NativeRuntimeExecutionRunner::new(processes)
}

pub(super) fn execution_spec<const N: usize>(
    address: &str,
    arguments: [&str; N],
) -> RuntimeExecutionSpec {
    let mut argv = Vec::with_capacity(arguments.len() + 1);
    argv.push(OsString::from(address));
    argv.extend(arguments.into_iter().map(OsString::from));
    RuntimeExecutionSpec::new(address, argv, "C:/fixture/project")
}

pub(super) fn assert_command_error(observer: &RecordingObserver, message: &str) {
    assert_eq!(
        observer.events(),
        vec![
            ObserverEvent::Output(ProcessOutputStream::Stderr, message.to_owned()),
            ObserverEvent::Completed(ProcessOutcome::Exited(1)),
        ]
    );
}

pub(super) struct FixedCoreTask(pub(super) Result<CoreCommandOutcome, String>);

impl CoreTask for FixedCoreTask {
    fn execute(self: Box<Self>) -> Result<CoreCommandOutcome, String> {
        self.0
    }
}

pub(super) struct BlockingCoreTask {
    pub(super) entered: mpsc::Sender<()>,
    pub(super) release: mpsc::Receiver<()>,
}

impl CoreTask for BlockingCoreTask {
    fn execute(self: Box<Self>) -> Result<CoreCommandOutcome, String> {
        self.entered.send(()).unwrap();
        self.release.recv().unwrap();
        Ok(CoreCommandOutcome::success(String::new()))
    }
}

pub(super) struct PanickingCoreTask;

impl CoreTask for PanickingCoreTask {
    fn execute(self: Box<Self>) -> Result<CoreCommandOutcome, String> {
        panic!("fixture execution panic")
    }
}

pub(super) struct FailingProcessTask(pub(super) &'static str);

impl ProcessTask for FailingProcessTask {
    fn materialize(self: Box<Self>) -> Result<ProcessLaunch, String> {
        Err(self.0.to_owned())
    }
}

pub(super) struct FixedProcessTask;

impl ProcessTask for FixedProcessTask {
    fn materialize(self: Box<Self>) -> Result<ProcessLaunch, String> {
        Ok(fixture_launch())
    }
}

pub(super) struct BlockingProcessTask {
    pub(super) entered: mpsc::Sender<()>,
    pub(super) release: mpsc::Receiver<()>,
}

impl ProcessTask for BlockingProcessTask {
    fn materialize(self: Box<Self>) -> Result<ProcessLaunch, String> {
        self.entered.send(()).unwrap();
        self.release.recv().unwrap();
        Ok(fixture_launch())
    }
}

fn fixture_launch() -> ProcessLaunch {
    ProcessLaunch::new(Command::new("fixture.exe"), "fixture", 0)
}

pub(super) struct UnusedProcessRunner;

impl ProcessRunner for UnusedProcessRunner {
    fn start(
        &self,
        _launch: ProcessLaunch,
        _observer: Arc<dyn ProcessObserver>,
    ) -> io::Result<Arc<dyn ProcessControl>> {
        panic!("process runner must not be called")
    }
}

pub(super) struct CountingUnusedRunner {
    pub(super) starts: Arc<AtomicUsize>,
}

impl ProcessRunner for CountingUnusedRunner {
    fn start(
        &self,
        _launch: ProcessLaunch,
        _observer: Arc<dyn ProcessObserver>,
    ) -> io::Result<Arc<dyn ProcessControl>> {
        self.starts.fetch_add(1, Ordering::AcqRel);
        panic!("process runner must not be called")
    }
}

pub(super) struct FailingProcessRunner;

impl ProcessRunner for FailingProcessRunner {
    fn start(
        &self,
        _launch: ProcessLaunch,
        _observer: Arc<dyn ProcessObserver>,
    ) -> io::Result<Arc<dyn ProcessControl>> {
        Err(io::Error::other("fixture process start failed"))
    }
}

pub(super) struct JoinFailingProcessRunner;

impl ProcessRunner for JoinFailingProcessRunner {
    fn start(
        &self,
        _launch: ProcessLaunch,
        _observer: Arc<dyn ProcessObserver>,
    ) -> io::Result<Arc<dyn ProcessControl>> {
        Ok(Arc::new(JoinFailingProcess))
    }
}

struct JoinFailingProcess;

impl ProcessControl for JoinFailingProcess {
    fn cancel(&self) -> io::Result<()> {
        Ok(())
    }

    fn join(&self) -> Result<(), String> {
        Err("fixture process join failed".to_owned())
    }
}

pub(super) struct ControllableProcessRunner {
    pub(super) canceled: Arc<AtomicBool>,
}

impl ProcessRunner for ControllableProcessRunner {
    fn start(
        &self,
        _launch: ProcessLaunch,
        observer: Arc<dyn ProcessObserver>,
    ) -> io::Result<Arc<dyn ProcessControl>> {
        Ok(Arc::new(ControllableProcess {
            canceled: Arc::clone(&self.canceled),
            completed: AtomicBool::new(false),
            observer,
        }))
    }
}

struct ControllableProcess {
    canceled: Arc<AtomicBool>,
    completed: AtomicBool,
    observer: Arc<dyn ProcessObserver>,
}

impl ProcessControl for ControllableProcess {
    fn cancel(&self) -> io::Result<()> {
        self.canceled.store(true, Ordering::Release);
        self.complete(1223);
        Ok(())
    }

    fn join(&self) -> Result<(), String> {
        self.complete(0);
        Ok(())
    }
}

impl ControllableProcess {
    fn complete(&self, exit_code: i32) {
        if self
            .completed
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
        {
            self.observer.completed(ProcessOutcome::Exited(exit_code));
        }
    }
}

pub(super) struct FailingExecutionThreadSpawner;

impl ExecutionThreadSpawner for FailingExecutionThreadSpawner {
    fn spawn(&self, _task: ExecutionTask) -> io::Result<thread::JoinHandle<Result<(), String>>> {
        Err(io::Error::other("fixture execution thread start failed"))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum ObserverEvent {
    Output(ProcessOutputStream, String),
    Progress,
    Completed(ProcessOutcome),
}

#[derive(Default)]
pub(super) struct RecordingObserver {
    events: Mutex<Vec<ObserverEvent>>,
}

impl RecordingObserver {
    pub(super) fn events(&self) -> Vec<ObserverEvent> {
        self.events.lock().unwrap().clone()
    }
}

impl ProcessObserver for RecordingObserver {
    fn output(&self, stream: ProcessOutputStream, text: String) {
        self.events
            .lock()
            .unwrap()
            .push(ObserverEvent::Output(stream, text));
    }

    fn progress(&self, _progress: CommandProgress) {
        self.events.lock().unwrap().push(ObserverEvent::Progress);
    }

    fn completed(&self, outcome: ProcessOutcome) {
        self.events
            .lock()
            .unwrap()
            .push(ObserverEvent::Completed(outcome));
    }
}
