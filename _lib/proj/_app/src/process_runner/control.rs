use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;

use crate::process_job::OwnedProcessJob;

use super::ProcessControl;

pub(super) struct NativeProcessControl {
    job: Arc<OwnedProcessJob>,
    completion: MonitorCompletion,
}

impl NativeProcessControl {
    pub(super) fn new(job: Arc<OwnedProcessJob>, monitor: JoinHandle<()>) -> Self {
        Self {
            job,
            completion: MonitorCompletion {
                state: Mutex::new(JoinState::Ready(Some(monitor))),
                changed: Condvar::new(),
            },
        }
    }

    #[cfg(test)]
    pub(super) fn wait_until_joining(&self) {
        let mut state = self.completion.state.lock().expect("monitor join state");
        while !matches!(*state, JoinState::Joining) {
            state = self
                .completion
                .changed
                .wait(state)
                .expect("monitor join state");
        }
    }
}

impl ProcessControl for NativeProcessControl {
    fn cancel(&self) -> std::io::Result<()> {
        self.job.cancel()
    }

    fn join(&self) -> Result<(), String> {
        let monitor = {
            let mut state = self
                .completion
                .state
                .lock()
                .map_err(|_| "command process monitor is unavailable".to_owned())?;
            loop {
                match &mut *state {
                    JoinState::Ready(monitor) => {
                        let monitor = monitor
                            .take()
                            .expect("ready monitor completion owns its thread");
                        *state = JoinState::Joining;
                        self.completion.changed.notify_all();
                        break monitor;
                    }
                    JoinState::Joining => {
                        state = self
                            .completion
                            .changed
                            .wait(state)
                            .map_err(|_| "command process monitor is unavailable".to_owned())?;
                    }
                    JoinState::Completed(result) => return result.clone(),
                }
            }
        };

        let result = monitor
            .join()
            .map_err(|_| "command process monitor panicked".to_owned());
        let mut state = self
            .completion
            .state
            .lock()
            .map_err(|_| "command process monitor is unavailable".to_owned())?;
        *state = JoinState::Completed(result.clone());
        self.completion.changed.notify_all();
        result
    }
}

impl Drop for NativeProcessControl {
    fn drop(&mut self) {
        let _ = self.job.cancel();
    }
}

struct MonitorCompletion {
    state: Mutex<JoinState>,
    changed: Condvar,
}

enum JoinState {
    Ready(Option<JoinHandle<()>>),
    Joining,
    Completed(Result<(), String>),
}
