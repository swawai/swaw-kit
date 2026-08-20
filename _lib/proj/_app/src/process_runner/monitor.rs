use std::io::{self, Read};
use std::process::Child;
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};

use crate::command_event::{CapturedCommandEvent, CommandEventFrameDecoder};
use crate::process_job::OwnedProcessJob;
use crate::utf8_output::Utf8LossyDecoder;

use super::{ProcessLabel, ProcessObserver, ProcessOutcome, ProcessOutputStream};

const OUTPUT_READ_BUFFER_SIZE: usize = 8192;

pub(super) trait MonitorSpawner {
    fn spawn(&self, task: MonitorTask) -> Result<JoinHandle<()>, MonitorSpawnFailure>;
}

pub(super) struct ThreadMonitorSpawner;

impl MonitorSpawner for ThreadMonitorSpawner {
    fn spawn(&self, task: MonitorTask) -> Result<JoinHandle<()>, MonitorSpawnFailure> {
        let task = Arc::new(Mutex::new(Some(task)));
        let thread_task = Arc::clone(&task);
        match thread::Builder::new()
            .name("swawkit-command-monitor".to_owned())
            .spawn(move || {
                let task = thread_task
                    .lock()
                    .expect("monitor start slot")
                    .take()
                    .expect("monitor start slot owns its task");
                run_monitor(task);
            }) {
            Ok(monitor) => Ok(monitor),
            Err(error) => {
                let task = task
                    .lock()
                    .expect("failed monitor start slot")
                    .take()
                    .expect("failed monitor start retains its task");
                Err(MonitorSpawnFailure { error, task })
            }
        }
    }
}

pub(super) struct MonitorSpawnFailure {
    pub(super) error: io::Error,
    pub(super) task: MonitorTask,
}

impl MonitorSpawnFailure {
    #[cfg(test)]
    pub(super) fn new(error: io::Error, task: MonitorTask) -> Self {
        Self { error, task }
    }
}

pub(super) struct MonitorTask {
    child: Child,
    job: Arc<OwnedProcessJob>,
    label: ProcessLabel,
    observer: Arc<dyn ProcessObserver>,
    stdout_thread: ReaderThread,
    stderr_thread: ReaderThread,
}

pub(super) fn start_monitored(
    mut child: Child,
    job: Arc<OwnedProcessJob>,
    label: ProcessLabel,
    observer: Arc<dyn ProcessObserver>,
    spawner: &dyn MonitorSpawner,
) -> io::Result<JoinHandle<()>> {
    let stdout = match child.stdout.take() {
        Some(stdout) => stdout,
        None => {
            let error = io::Error::other(format!("{} stdout pipe is unavailable", label.subject));
            let cleanup = cleanup_unmonitored(&mut child, &job, &label.subject, std::iter::empty());
            return Err(attach_cleanup(error, cleanup));
        }
    };
    let stderr = match child.stderr.take() {
        Some(stderr) => stderr,
        None => {
            drop(stdout);
            let error = io::Error::other(format!("{} stderr pipe is unavailable", label.subject));
            let cleanup = cleanup_unmonitored(&mut child, &job, &label.subject, std::iter::empty());
            return Err(attach_cleanup(error, cleanup));
        }
    };
    let gate = Arc::new(StartGate::default());
    let stdout_thread = match spawn_reader(
        stdout,
        ProcessOutputStream::Stdout,
        Arc::clone(&observer),
        Arc::clone(&gate),
    ) {
        Ok(thread) => thread,
        Err(error) => {
            gate.reject();
            drop(stderr);
            let cleanup = cleanup_unmonitored(&mut child, &job, &label.subject, std::iter::empty());
            return Err(attach_cleanup(error, cleanup));
        }
    };
    let stderr_thread = match spawn_reader(
        stderr,
        ProcessOutputStream::Stderr,
        Arc::clone(&observer),
        Arc::clone(&gate),
    ) {
        Ok(thread) => thread,
        Err(error) => {
            gate.reject();
            let cleanup = cleanup_unmonitored(
                &mut child,
                &job,
                &label.subject,
                std::iter::once(stdout_thread),
            );
            return Err(attach_cleanup(error, cleanup));
        }
    };
    let task = MonitorTask {
        child,
        job,
        label,
        observer,
        stdout_thread,
        stderr_thread,
    };
    match spawner.spawn(task) {
        Ok(monitor) => {
            gate.accept();
            Ok(monitor)
        }
        Err(MonitorSpawnFailure { error, mut task }) => {
            gate.reject();
            let cleanup = cleanup_unmonitored(
                &mut task.child,
                &task.job,
                &task.label.subject,
                [task.stdout_thread, task.stderr_thread],
            );
            Err(attach_cleanup(error, cleanup))
        }
    }
}

fn run_monitor(mut task: MonitorTask) {
    let wait = task.child.wait();
    let cleanup = task.job.terminate_remaining();
    let stdout = task.stdout_thread.join(&task.label.subject);
    let stderr = task.stderr_thread.join(&task.label.subject);
    let outcome = match (wait, cleanup, stdout, stderr) {
        (Ok(status), Ok(()), Ok(()), Ok(())) => ProcessOutcome::Exited(status.code().unwrap_or(1)),
        (wait, cleanup, stdout, stderr) => ProcessOutcome::Failed(monitor_error(
            &task.label.subject,
            wait.err(),
            cleanup.err(),
            stdout.err(),
            stderr.err(),
        )),
    };
    task.observer.completed(outcome);
}

fn cleanup_unmonitored(
    child: &mut Child,
    job: &OwnedProcessJob,
    subject: &str,
    readers: impl IntoIterator<Item = ReaderThread>,
) -> Vec<String> {
    let mut errors = Vec::new();
    if let Err(cancel_error) = job.cancel() {
        errors.push(format!("cannot cancel the {subject}: {cancel_error}"));
        if let Err(kill_error) = child.kill() {
            errors.push(format!("cannot kill the {subject}: {kill_error}"));
        }
    }
    if let Err(error) = child.wait() {
        errors.push(format!("cannot wait for the {subject}: {error}"));
    }
    for reader in readers {
        if let Err(error) = reader.join(subject) {
            errors.push(error);
        }
    }
    errors
}

fn attach_cleanup(primary: io::Error, cleanup: Vec<String>) -> io::Error {
    if cleanup.is_empty() {
        return primary;
    }
    io::Error::new(
        primary.kind(),
        format!("{primary}; additionally, {}", cleanup.join("; ")),
    )
}

fn spawn_reader<R>(
    reader: R,
    stream: ProcessOutputStream,
    observer: Arc<dyn ProcessObserver>,
    gate: Arc<StartGate>,
) -> io::Result<ReaderThread>
where
    R: Read + Send + 'static,
{
    let stream_name = match stream {
        ProcessOutputStream::Stdout => "stdout",
        ProcessOutputStream::Stderr => "stderr",
    };
    let handle = thread::Builder::new()
        .name(
            match stream {
                ProcessOutputStream::Stdout => "swawkit-command-stdout",
                ProcessOutputStream::Stderr => "swawkit-command-stderr",
            }
            .to_owned(),
        )
        .spawn(move || {
            if gate.wait() {
                read_output(reader, stream, observer)
            } else {
                Ok(())
            }
        })?;
    Ok(ReaderThread {
        stream: stream_name,
        handle,
    })
}

fn read_output(
    mut reader: impl Read,
    stream: ProcessOutputStream,
    observer: Arc<dyn ProcessObserver>,
) -> io::Result<()> {
    let mut buffer = [0_u8; OUTPUT_READ_BUFFER_SIZE];
    let mut decoder = Utf8LossyDecoder::default();
    let mut frame_decoder = CommandEventFrameDecoder::default();
    loop {
        let count = reader.read(&mut buffer)?;
        if count == 0 {
            if let Some(text) = decoder.decode(&[], true) {
                dispatch_output(&observer, stream, frame_decoder.push(&text));
            }
            dispatch_output(&observer, stream, frame_decoder.finish());
            return Ok(());
        }
        if let Some(text) = decoder.decode(&buffer[..count], false) {
            dispatch_output(&observer, stream, frame_decoder.push(&text));
        }
    }
}

fn dispatch_output(
    observer: &Arc<dyn ProcessObserver>,
    stream: ProcessOutputStream,
    events: Vec<CapturedCommandEvent>,
) {
    for event in events {
        match event {
            CapturedCommandEvent::Output(text) => observer.output(stream, text),
            CapturedCommandEvent::Progress(progress) => observer.progress(progress),
        }
    }
}

struct ReaderThread {
    stream: &'static str,
    handle: JoinHandle<io::Result<()>>,
}

impl ReaderThread {
    fn join(self, subject: &str) -> Result<(), String> {
        self.handle
            .join()
            .map_err(|_| format!("{subject} {} reader panicked", self.stream))?
            .map_err(|error| format!("{subject} {} reader failed: {error}", self.stream))
    }
}

fn monitor_error(
    subject: &str,
    wait: Option<io::Error>,
    cleanup: Option<io::Error>,
    stdout: Option<String>,
    stderr: Option<String>,
) -> String {
    let mut errors = Vec::new();
    if let Some(error) = wait {
        errors.push(format!("cannot wait for the {subject}: {error}"));
    }
    if let Some(error) = cleanup {
        errors.push(error.to_string());
    }
    errors.extend(stdout);
    errors.extend(stderr);
    errors.join("; ")
}

#[derive(Default)]
struct StartGate {
    state: Mutex<StartGateState>,
    changed: Condvar,
}

impl StartGate {
    fn accept(&self) {
        self.set(StartGateState::Accepted);
    }

    fn reject(&self) {
        self.set(StartGateState::Rejected);
    }

    fn set(&self, next: StartGateState) {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        *state = next;
        self.changed.notify_all();
    }

    fn wait(&self) -> bool {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        while *state == StartGateState::Pending {
            state = self
                .changed
                .wait(state)
                .unwrap_or_else(|error| error.into_inner());
        }
        *state == StartGateState::Accepted
    }
}

#[derive(Clone, Copy, Default, PartialEq, Eq)]
enum StartGateState {
    #[default]
    Pending,
    Accepted,
    Rejected,
}

#[cfg(test)]
pub(super) fn merged_cleanup_error(primary: io::Error, cleanup: Vec<String>) -> io::Error {
    attach_cleanup(primary, cleanup)
}
