use std::{error::Error, fmt};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProfileError {
    message: String,
}

impl ProfileError {
    pub(crate) fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl fmt::Display for ProfileError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl Error for ProfileError {}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProfileUpdateError {
    Conflict { current_revision: String },
    Profile(ProfileError),
}

impl fmt::Display for ProfileUpdateError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Conflict { .. } => {
                formatter.write_str("entry profile changed since it was loaded")
            }
            Self::Profile(error) => error.fmt(formatter),
        }
    }
}

impl Error for ProfileUpdateError {}

#[derive(Debug)]
pub(super) struct ProfileReadError {
    message: String,
    pub(super) revision: Option<String>,
}

impl ProfileReadError {
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

impl From<ProfileError> for ProfileReadError {
    fn from(error: ProfileError) -> Self {
        Self::new(error.to_string())
    }
}

impl fmt::Display for ProfileReadError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl Error for ProfileReadError {}
