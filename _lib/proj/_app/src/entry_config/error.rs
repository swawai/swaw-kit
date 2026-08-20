use std::{error::Error, fmt};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EntryConfigError {
    message: String,
}

impl EntryConfigError {
    pub(crate) fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl fmt::Display for EntryConfigError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl Error for EntryConfigError {}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EntryConfigUpdateError {
    Conflict { current_revision: String },
    Config(EntryConfigError),
}

impl fmt::Display for EntryConfigUpdateError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Conflict { .. } => {
                formatter.write_str("entry config changed since it was loaded")
            }
            Self::Config(error) => error.fmt(formatter),
        }
    }
}

impl Error for EntryConfigUpdateError {}

#[derive(Debug)]
pub(super) struct EntryConfigReadError {
    message: String,
    pub(super) revision: Option<String>,
}

impl EntryConfigReadError {
    pub(super) fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            revision: None,
        }
    }

    pub(super) fn with_revision(message: impl Into<String>, revision: String) -> Self {
        Self {
            message: message.into(),
            revision: Some(revision),
        }
    }
}

impl From<EntryConfigError> for EntryConfigReadError {
    fn from(error: EntryConfigError) -> Self {
        Self::new(error.to_string())
    }
}

impl fmt::Display for EntryConfigReadError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl Error for EntryConfigReadError {}
