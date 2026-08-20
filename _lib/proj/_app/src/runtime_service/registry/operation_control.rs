use std::io;
use std::sync::{Arc, Condvar, Mutex};

use crate::process_runner::ProcessControl;
use crate::runtime_service::RuntimeServiceError;

pub(super) struct OperationControl {
    state: Mutex<OperationControlState>,
    changed: Condvar,
}

enum OperationControlState {
    Starting {
        cancel_requested: bool,
    },
    Canceling,
    Attached {
        control: Arc<dyn ProcessControl>,
        cancel_requested: bool,
        cancel_error: Option<String>,
    },
    StartFailed,
}

impl OperationControl {
    pub(super) fn new() -> Self {
        Self {
            state: Mutex::new(OperationControlState::Starting {
                cancel_requested: false,
            }),
            changed: Condvar::new(),
        }
    }

    pub(super) fn attach(
        &self,
        control: Arc<dyn ProcessControl>,
    ) -> Result<(), RuntimeServiceError> {
        let should_cancel = {
            let mut state = self
                .state
                .lock()
                .map_err(|_| RuntimeServiceError::RegistryUnavailable)?;
            let OperationControlState::Starting { cancel_requested } = &*state else {
                return Err(RuntimeServiceError::RegistryUnavailable);
            };
            let should_cancel = *cancel_requested;
            *state = if should_cancel {
                OperationControlState::Canceling
            } else {
                OperationControlState::Attached {
                    control: Arc::clone(&control),
                    cancel_requested: false,
                    cancel_error: None,
                }
            };
            if !should_cancel {
                self.changed.notify_all();
            }
            should_cancel
        };
        if should_cancel {
            self.finish_cancel(control);
        }
        Ok(())
    }

    pub(super) fn start_failed(&self) -> Result<(), RuntimeServiceError> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| RuntimeServiceError::RegistryUnavailable)?;
        if !matches!(*state, OperationControlState::Starting { .. }) {
            return Err(RuntimeServiceError::RegistryUnavailable);
        }
        *state = OperationControlState::StartFailed;
        self.changed.notify_all();
        Ok(())
    }

    pub(super) fn begin_cancel(&self) -> io::Result<()> {
        let control = {
            let mut state = self.lock_io()?;
            match &mut *state {
                OperationControlState::Starting { cancel_requested } => {
                    *cancel_requested = true;
                    None
                }
                OperationControlState::Attached {
                    control,
                    cancel_requested,
                    ..
                } if !*cancel_requested => {
                    let control = Arc::clone(control);
                    *state = OperationControlState::Canceling;
                    Some(control)
                }
                OperationControlState::Canceling
                | OperationControlState::Attached { .. }
                | OperationControlState::StartFailed => None,
            }
        };
        if let Some(control) = control {
            self.finish_cancel(control);
        }
        Ok(())
    }

    fn finish_cancel(&self, control: Arc<dyn ProcessControl>) {
        let error = control.cancel().err().map(|error| error.to_string());
        if let Ok(mut state) = self.state.lock() {
            if matches!(*state, OperationControlState::Canceling) {
                *state = OperationControlState::Attached {
                    control,
                    cancel_requested: true,
                    cancel_error: error,
                };
            }
            self.changed.notify_all();
        }
    }

    pub(super) fn cancel_result(&self) -> io::Result<()> {
        let mut state = self.lock_io()?;
        loop {
            match &*state {
                OperationControlState::Starting {
                    cancel_requested: true,
                }
                | OperationControlState::Canceling => {
                    state = self
                        .changed
                        .wait(state)
                        .map_err(|_| unavailable_control())?;
                }
                OperationControlState::Attached {
                    cancel_requested: true,
                    cancel_error,
                    ..
                } => {
                    return cancel_error
                        .as_ref()
                        .map_or(Ok(()), |error| Err(io::Error::other(error.clone())));
                }
                OperationControlState::StartFailed => return Ok(()),
                OperationControlState::Starting {
                    cancel_requested: false,
                }
                | OperationControlState::Attached {
                    cancel_requested: false,
                    ..
                } => return Err(io::Error::other("operation cancellation was not requested")),
            }
        }
    }

    pub(super) fn cancel(&self) -> io::Result<()> {
        self.begin_cancel()?;
        self.cancel_result()
    }

    pub(super) fn join(&self) -> Result<(), String> {
        let control = {
            let mut state = self
                .state
                .lock()
                .map_err(|_| "operation control is unavailable".to_owned())?;
            loop {
                match &*state {
                    OperationControlState::Starting { .. } | OperationControlState::Canceling => {
                        state = self
                            .changed
                            .wait(state)
                            .map_err(|_| "operation control is unavailable".to_owned())?;
                    }
                    OperationControlState::Attached { control, .. } => {
                        break Some(Arc::clone(control));
                    }
                    OperationControlState::StartFailed => break None,
                }
            }
        };
        control.map_or(Ok(()), |control| control.join())
    }

    fn lock_io(&self) -> io::Result<std::sync::MutexGuard<'_, OperationControlState>> {
        self.state.lock().map_err(|_| unavailable_control())
    }
}

fn unavailable_control() -> io::Error {
    io::Error::other("operation control is unavailable")
}
