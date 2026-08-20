use std::error::Error;
use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EntryManagerErrorKind {
    InvalidName,
    ManagerOnly,
    Conflict,
    Corrupt,
    Io,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EntryManagerError {
    kind: EntryManagerErrorKind,
    message: String,
}

impl EntryManagerError {
    pub(crate) fn new(kind: EntryManagerErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }

    pub(crate) fn invalid_name(message: impl Into<String>) -> Self {
        Self::new(EntryManagerErrorKind::InvalidName, message)
    }

    pub(crate) fn conflict(message: impl Into<String>) -> Self {
        Self::new(EntryManagerErrorKind::Conflict, message)
    }

    pub(crate) fn corrupt(message: impl Into<String>) -> Self {
        Self::new(EntryManagerErrorKind::Corrupt, message)
    }

    pub(crate) fn io(action: &str, error: std::io::Error) -> Self {
        Self::new(
            EntryManagerErrorKind::Io,
            format!("cannot {action}: {error}"),
        )
    }

    pub fn kind(&self) -> EntryManagerErrorKind {
        self.kind
    }
}

impl fmt::Display for EntryManagerError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl Error for EntryManagerError {}
