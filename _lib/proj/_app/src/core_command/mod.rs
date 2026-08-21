//! Transport-neutral implementations of the small, process-owned Core commands.

pub mod check;
pub mod config;
mod error;
pub mod facet_route;
pub mod help;
mod prepared;
pub mod runs;
pub mod view;

pub use error::CoreCommandError;
pub(crate) use prepared::PreparedCoreCommand;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CoreCommandOutcome {
    pub exit_code: i32,
    /// Complete stdout text, including the final newline emitted by the command.
    pub stdout: String,
}

impl CoreCommandOutcome {
    pub fn success(stdout: impl Into<String>) -> Self {
        Self {
            exit_code: 0,
            stdout: stdout.into(),
        }
    }

    pub fn with_exit_code(exit_code: i32, stdout: impl Into<String>) -> Self {
        Self {
            exit_code,
            stdout: stdout.into(),
        }
    }
}
