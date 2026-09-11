mod console_cancel;
mod environment;
mod execute;
mod invocation;
mod prepared;
mod process;
mod resolve;

pub use console_cancel::ConsoleCancellation;
pub use environment::{
    CommandExecutionContext, CommandProcessMode, catalog_command_data_root,
    catalog_command_data_root_from_roots,
};
pub(crate) use environment::{
    ProcessEnvironment, command_data_root, validate_dev_executable, validate_module_executable,
};
pub use execute::CommandExecutor;
pub(crate) use invocation::Invocation;
pub(crate) use prepared::{PlannedCommand, PreparedCommand};
pub(crate) use resolve::ResolvedCommand;

use std::error::Error;
use std::fmt;

pub type CommandResult<T> = Result<T, CommandError>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandError {
    message: String,
}

impl CommandError {
    pub(crate) fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl fmt::Display for CommandError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl Error for CommandError {}

#[cfg(test)]
mod tests;
