mod control;
mod monitor;

use std::ffi::OsStr;
use std::io;
use std::os::windows::process::CommandExt;
use std::process::{Command, Stdio};
use std::sync::Arc;

use windows_sys::Win32::System::Threading::CREATE_SUSPENDED;

use crate::command_event::CommandProgress;
use crate::process_job::OwnedProcessJob;
use control::NativeProcessControl;
use monitor::{MonitorSpawner, ThreadMonitorSpawner, start_monitored};

const MAX_PROCESS_SUBJECT_UTF16: usize = 64;
const MAX_PROCESS_LABEL_UTF16: usize = 512;
const PROCESS_LABEL_DECORATION_UTF16: usize = 7;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ProcessOutputStream {
    Stdout,
    Stderr,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ProcessOutcome {
    Exited(i32),
    Failed(String),
}

pub(crate) trait ProcessObserver: Send + Sync {
    fn output(&self, stream: ProcessOutputStream, text: String);
    fn progress(&self, progress: CommandProgress);
    fn completed(&self, outcome: ProcessOutcome);
}

pub(crate) trait ProcessControl: Send + Sync {
    fn cancel(&self) -> io::Result<()>;
    fn join(&self) -> Result<(), String>;
}

pub(crate) trait ProcessRunner: Send + Sync {
    /// Starts one process. On `Err`, the runner must not later call the observer.
    fn start(
        &self,
        launch: ProcessLaunch,
        observer: Arc<dyn ProcessObserver>,
    ) -> io::Result<Arc<dyn ProcessControl>>;
}

pub(crate) struct ProcessLaunch {
    command: Command,
    label: ProcessLabel,
    base_creation_flags: u32,
}

impl ProcessLaunch {
    pub(crate) fn new(command: Command, subject: &str, base_creation_flags: u32) -> Self {
        let target = command.get_program().to_owned();
        Self {
            command,
            label: ProcessLabel::new(subject, &target),
            base_creation_flags,
        }
    }

    #[cfg(test)]
    pub(crate) fn command(&self) -> &Command {
        &self.command
    }

    #[cfg(test)]
    pub(crate) fn base_creation_flags(&self) -> u32 {
        self.base_creation_flags
    }
}

struct ProcessLabel {
    subject: String,
    target: String,
}

impl ProcessLabel {
    fn new(subject: &str, target: &OsStr) -> Self {
        let subject = bounded_utf16(subject, MAX_PROCESS_SUBJECT_UTF16);
        let target_limit = MAX_PROCESS_LABEL_UTF16
            .saturating_sub(subject.encode_utf16().count())
            .saturating_sub(PROCESS_LABEL_DECORATION_UTF16);
        Self {
            subject,
            target: bounded_utf16(&target.to_string_lossy(), target_limit),
        }
    }

    fn start_description(&self) -> String {
        format!("the {} '{}'", self.subject, self.target)
    }
}

#[derive(Debug, Default)]
pub(crate) struct NativeProcessRunner;

impl NativeProcessRunner {
    fn start_with_monitor_spawner(
        &self,
        launch: ProcessLaunch,
        observer: Arc<dyn ProcessObserver>,
        monitor_spawner: &dyn MonitorSpawner,
    ) -> io::Result<Arc<dyn ProcessControl>> {
        let ProcessLaunch {
            mut command,
            label,
            base_creation_flags,
        } = launch;
        command
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .creation_flags(base_creation_flags | CREATE_SUSPENDED);

        let job = Arc::new(OwnedProcessJob::create()?);
        let mut child = command.spawn().map_err(|error| {
            io::Error::new(
                error.kind(),
                format!("cannot start {}: {error}", label.start_description()),
            )
        })?;
        if let Err(error) = job.assign_and_resume(&mut child) {
            return Err(failed_before_start(
                child,
                &job,
                &format!(
                    "cannot establish the {} process boundary: {error}",
                    label.subject
                ),
            ));
        }
        let monitor = start_monitored(child, Arc::clone(&job), label, observer, monitor_spawner)?;
        Ok(Arc::new(NativeProcessControl::new(job, monitor)))
    }
}

impl ProcessRunner for NativeProcessRunner {
    fn start(
        &self,
        launch: ProcessLaunch,
        observer: Arc<dyn ProcessObserver>,
    ) -> io::Result<Arc<dyn ProcessControl>> {
        self.start_with_monitor_spawner(launch, observer, &ThreadMonitorSpawner)
    }
}

fn failed_before_start(
    mut child: std::process::Child,
    job: &OwnedProcessJob,
    reason: &str,
) -> io::Error {
    let _ = job.cancel();
    let _ = child.kill();
    let output = child.wait_with_output();
    let detail = output
        .ok()
        .map(|output| String::from_utf8_lossy(&output.stderr).trim().to_owned())
        .filter(|detail| !detail.is_empty());
    io::Error::other(match detail {
        Some(detail) => format!("{reason}: {detail}"),
        None => reason.to_owned(),
    })
}

fn bounded_utf16(text: &str, limit: usize) -> String {
    if text.encode_utf16().count() <= limit {
        return text.to_owned();
    }
    let content_limit = limit.saturating_sub(1);
    let mut units = 0;
    let mut value = String::new();
    for character in text.chars() {
        let character_units = character.len_utf16();
        if units + character_units > content_limit {
            break;
        }
        value.push(character);
        units += character_units;
    }
    value.push('\u{2026}');
    value
}

#[cfg(test)]
mod tests;
