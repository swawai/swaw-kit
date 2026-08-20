use std::collections::VecDeque;
use std::io;
use std::sync::{Arc, Mutex, Weak};

use crate::command_event::CommandProgress;
use crate::process_runner::{ProcessControl, ProcessObserver, ProcessOutcome, ProcessOutputStream};
use crate::run_journal::{RunJournal, RunJournalEvent, RunJournalPhase, RunJournalStream};

use super::{OperationControl, RegistryInner};
use crate::runtime_service::{
    COMMAND_RUN_PROTOCOL, CommandRunDocument, CommandRunState, RuntimeServiceError,
};

const MAX_OUTPUT_BYTES: usize = 1024 * 1024;
pub(super) const MAX_OUTPUT_EVENTS: usize = 4096;

pub(super) struct CommandRun {
    pub(super) id: String,
    address: String,
    journal: RunJournal,
    state: Mutex<RunState>,
    control: OperationControl,
    cancelable: bool,
}

impl CommandRun {
    pub(super) fn new(id: String, address: String, journal: RunJournal, cancelable: bool) -> Self {
        Self {
            id,
            address,
            journal,
            state: Mutex::new(RunState::default()),
            control: OperationControl::new(),
            cancelable,
        }
    }

    pub(super) fn attach_control(
        &self,
        control: Arc<dyn ProcessControl>,
    ) -> Result<(), RuntimeServiceError> {
        self.control.attach(control)
    }

    pub(super) fn start_failed(&self) -> Result<(), RuntimeServiceError> {
        self.control.start_failed()
    }

    pub(super) fn cancel(&self) -> Result<(), RuntimeServiceError> {
        if !self.cancelable {
            let state = self
                .state
                .lock()
                .map_err(|_| RuntimeServiceError::RegistryUnavailable)?;
            return if state.status == CommandRunState::Running {
                Err(RuntimeServiceError::RunNotCancelable)
            } else {
                Ok(())
            };
        }
        if !self.begin_cancel().map_err(RuntimeServiceError::Cancel)? {
            return Ok(());
        }
        let result = self.control.cancel();
        if let Err(error) = result {
            let error = self
                .rollback_cancel(error)
                .map_err(RuntimeServiceError::Cancel)?;
            return Err(RuntimeServiceError::Cancel(error));
        }
        Ok(())
    }

    pub(super) fn begin_shutdown_cancel(&self) -> io::Result<()> {
        if !self.cancelable {
            return Ok(());
        }
        if self.begin_cancel()? {
            self.control.begin_cancel()?;
        }
        Ok(())
    }

    pub(super) fn finish_shutdown_cancel(&self) -> io::Result<()> {
        let should_finish = self
            .state
            .lock()
            .map_err(|_| io::Error::other("command run state is unavailable"))?
            .status
            == CommandRunState::Canceling;
        if !should_finish {
            return Ok(());
        }
        match self.control.cancel_result() {
            Ok(()) => Ok(()),
            Err(error) => Err(self.rollback_cancel(error)?),
        }
    }

    pub(super) fn join_control(&self) -> Result<(), String> {
        self.control.join()
    }

    fn begin_cancel(&self) -> io::Result<bool> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| io::Error::other("command run state is unavailable"))?;
        if state.status != CommandRunState::Running {
            return Ok(false);
        }
        state.status = CommandRunState::Canceling;
        Ok(true)
    }

    fn rollback_cancel(&self, error: io::Error) -> io::Result<io::Error> {
        let rollback = self
            .state
            .lock()
            .map_err(|_| io::Error::other("command run state is unavailable"))
            .map(|mut state| {
                if state.status == CommandRunState::Canceling {
                    state.status = CommandRunState::Running;
                }
            });
        match rollback {
            Ok(()) => Ok(error),
            Err(rollback_error) => Ok(io::Error::other(format!(
                "{error}; additionally, cancellation rollback failed: {rollback_error}"
            ))),
        }
    }

    pub(super) fn append(&self, stream: ProcessOutputStream, text: String) {
        if text.is_empty() {
            return;
        }
        self.append_journal_event(|journal| {
            journal.output(
                RunJournalPhase::Worker,
                match stream {
                    ProcessOutputStream::Stdout => RunJournalStream::Stdout,
                    ProcessOutputStream::Stderr => RunJournalStream::Stderr,
                },
                text,
            )
        });
    }

    pub(super) fn append_progress(&self, progress: CommandProgress) {
        self.append_journal_event(|journal| {
            journal
                .progress(RunJournalPhase::Worker, progress)
                .map(Some)
        });
    }

    fn append_journal_event(
        &self,
        append: impl FnOnce(&RunJournal) -> io::Result<Option<RunJournalEvent>>,
    ) {
        let Ok(mut state) = self.state.lock() else {
            return;
        };
        if state.status.is_terminal() {
            return;
        }
        let event = if state.journal_error.is_none() {
            match append(&self.journal) {
                Ok(Some(event)) => event,
                Ok(None) => return,
                Err(error) => {
                    state.journal_error = Some(error.to_string());
                    return;
                }
            }
        } else {
            return;
        };
        state.next_cursor = event.sequence;
        state.output_bytes += event.retained_bytes();
        state.events.push_back(event);
        while state.output_bytes > MAX_OUTPUT_BYTES || state.events.len() > MAX_OUTPUT_EVENTS {
            let Some(removed) = state.events.pop_front() else {
                break;
            };
            state.output_bytes -= removed.retained_bytes();
            state.truncated = true;
        }
    }

    pub(super) fn complete(&self, outcome: ProcessOutcome) -> bool {
        let Ok(mut state) = self.state.lock() else {
            return false;
        };
        if state.status.is_terminal() {
            return false;
        }
        if state.status == CommandRunState::Canceling {
            match self.journal.finish_canceled() {
                Ok(()) => {
                    state.status = CommandRunState::Canceled;
                    state.exit_code = None;
                    state.error = None;
                }
                Err(error) => journal_failed(&mut state, error),
            }
        } else {
            match outcome {
                ProcessOutcome::Exited(exit_code) => match self.journal.finish_exited(exit_code) {
                    Ok(()) => {
                        state.status = CommandRunState::Exited;
                        state.exit_code = Some(exit_code);
                        state.error = None;
                    }
                    Err(error) => journal_failed(&mut state, error),
                },
                ProcessOutcome::Failed(error) => match self.journal.finish_failed(error.clone()) {
                    Ok(()) => {
                        state.status = CommandRunState::Failed;
                        state.exit_code = None;
                        state.error = Some(error);
                    }
                    Err(journal_error) => {
                        state.status = CommandRunState::Failed;
                        state.exit_code = None;
                        state.error = Some(format!(
                            "{error}; additionally, command journal completion failed: {journal_error}"
                        ));
                    }
                },
            }
        }
        true
    }

    pub(super) fn fail_start(&self, error: String) {
        let Ok(mut state) = self.state.lock() else {
            return;
        };
        if state.status.is_terminal() {
            return;
        }
        match self.journal.finish_failed(error.clone()) {
            Ok(()) => {
                state.status = CommandRunState::Failed;
                state.exit_code = None;
                state.error = Some(error);
            }
            Err(journal_error) => {
                state.status = CommandRunState::Failed;
                state.exit_code = None;
                state.error = Some(format!(
                    "{error}; additionally, command journal completion failed: {journal_error}"
                ));
            }
        }
    }

    pub(super) fn document(&self, after: u64) -> Result<CommandRunDocument, RuntimeServiceError> {
        let state = self
            .state
            .lock()
            .map_err(|_| RuntimeServiceError::RegistryUnavailable)?;
        Ok(CommandRunDocument {
            protocol: COMMAND_RUN_PROTOCOL,
            id: self.id.clone(),
            address: self.address.clone(),
            state: state.status,
            exit_code: state.exit_code,
            error: state.error.clone(),
            next_cursor: state.next_cursor,
            events: state
                .events
                .iter()
                .filter(|event| event.sequence > after)
                .cloned()
                .collect(),
            truncated: state.truncated,
        })
    }

    pub(super) fn is_terminal(&self) -> bool {
        self.state
            .lock()
            .map(|state| state.status.is_terminal())
            .unwrap_or(true)
    }
}

#[derive(Default)]
struct RunState {
    status: CommandRunState,
    exit_code: Option<i32>,
    error: Option<String>,
    next_cursor: u64,
    events: VecDeque<RunJournalEvent>,
    output_bytes: usize,
    truncated: bool,
    journal_error: Option<String>,
}

fn journal_failed(state: &mut RunState, error: io::Error) {
    let prior = state
        .journal_error
        .take()
        .map(|prior| format!("{prior}; completion: {error}"))
        .unwrap_or_else(|| error.to_string());
    state.status = CommandRunState::Failed;
    state.exit_code = None;
    state.error = Some(format!("command journal failed: {prior}"));
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::run_journal::{RunJournalSource, StartRunJournal};

    #[test]
    fn a_running_core_command_has_a_typed_non_cancelable_result() {
        let root =
            std::env::temp_dir().join(format!("swawkit-noncancelable-run-{}", std::process::id()));
        let journal = RunJournal::start(StartRunJournal {
            module_data_root: root.clone(),
            address: ".fixture".to_owned(),
            source: RunJournalSource::Web,
            argument_count: 0,
            profile_revision: "sha256-fixture".to_owned(),
        })
        .expect("start non-cancelable fixture journal");
        let run = CommandRun::new(
            journal.id().expect("fixture journal id"),
            ".fixture".to_owned(),
            journal,
            false,
        );

        assert!(matches!(
            run.cancel(),
            Err(RuntimeServiceError::RunNotCancelable)
        ));
        assert_eq!(
            run.document(0).expect("fixture run document").state,
            CommandRunState::Running
        );
        drop(run);
        let _ = std::fs::remove_dir_all(root);
    }
}

pub(super) struct RunObserver {
    pub(super) run: Weak<CommandRun>,
    pub(super) registry: Weak<RegistryInner>,
}

impl ProcessObserver for RunObserver {
    fn output(&self, stream: ProcessOutputStream, text: String) {
        if let Some(run) = self.run.upgrade() {
            run.append(stream, text);
        }
    }

    fn progress(&self, progress: CommandProgress) {
        if let Some(run) = self.run.upgrade() {
            run.append_progress(progress);
        }
    }

    fn completed(&self, outcome: ProcessOutcome) {
        if self.run.upgrade().is_some_and(|run| run.complete(outcome))
            && let Some(registry) = self.registry.upgrade()
        {
            registry.completed_run();
        }
    }
}
