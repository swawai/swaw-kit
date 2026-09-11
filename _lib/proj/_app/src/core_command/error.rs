use std::error::Error;
use std::fmt;
use std::io;

#[derive(Debug)]
pub enum CoreCommandError {
    Arguments {
        message: String,
    },
    Domain {
        message: String,
    },
    Io {
        message: String,
        source: io::Error,
    },
    Serialization {
        message: String,
        source: serde_json::Error,
    },
}

impl CoreCommandError {
    pub(crate) fn arguments(message: impl Into<String>) -> Self {
        Self::Arguments {
            message: message.into(),
        }
    }

    pub(crate) fn domain(message: impl Into<String>) -> Self {
        Self::Domain {
            message: message.into(),
        }
    }

    pub(crate) fn io(message: impl Into<String>, source: io::Error) -> Self {
        Self::Io {
            message: format!("{}: {source}", message.into()),
            source,
        }
    }

    pub(crate) fn serialization(message: impl Into<String>, source: serde_json::Error) -> Self {
        Self::Serialization {
            message: format!("{}: {source}", message.into()),
            source,
        }
    }
}

impl fmt::Display for CoreCommandError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::Arguments { message }
            | Self::Domain { message }
            | Self::Io { message, .. }
            | Self::Serialization { message, .. } => message,
        };
        formatter.write_str(message)
    }
}

impl Error for CoreCommandError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Io { source, .. } => Some(source),
            Self::Serialization { source, .. } => Some(source),
            Self::Arguments { .. } | Self::Domain { .. } => None,
        }
    }
}
