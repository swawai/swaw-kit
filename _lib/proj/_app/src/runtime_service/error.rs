use std::fmt;
use std::io;

#[derive(Debug)]
pub(crate) enum RuntimeServiceError {
    InvalidRequest(&'static str),
    ProfileSetupRequired,
    ProfileInvalid(String),
    CatalogDiscovery,
    CommandNotFound,
    CommandInvalid(String),
    LifecycleCommandUnsupported,
    DependenciesNotReady(String),
    ExecutionContext(String),
    CommandDataRoot(String),
    PreparationWorker(String),
    RunWorker(String),
    CancellationWorker(String),
    Capacity,
    RunNotFound,
    RunNotCancelable,
    RuntimeUpdateRequired {
        running_release_id: String,
        selected_release_id: String,
    },
    RuntimeGenerationUnavailable(String),
    ShuttingDown,
    Start(io::Error),
    Journal(io::Error),
    Cancel(io::Error),
    RegistryUnavailable,
    Query(String),
    Shutdown(String),
}

impl fmt::Display for RuntimeServiceError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidRequest(error) => formatter.write_str(error),
            Self::ProfileSetupRequired => {
                formatter.write_str("entry profile setup is required before running commands")
            }
            Self::ProfileInvalid(error) => {
                write!(formatter, "entry profile is invalid: {error}")
            }
            Self::CatalogDiscovery => formatter.write_str("catalog discovery failed"),
            Self::CommandNotFound => formatter.write_str("command not found"),
            Self::CommandInvalid(error)
            | Self::DependenciesNotReady(error)
            | Self::ExecutionContext(error)
            | Self::CommandDataRoot(error)
            | Self::Query(error)
            | Self::Shutdown(error) => formatter.write_str(error),
            Self::LifecycleCommandUnsupported => formatter
                .write_str("in-process System lifecycle commands are not runtime-dispatchable"),
            Self::PreparationWorker(error) => {
                write!(formatter, "command preparation worker failed: {error}")
            }
            Self::RunWorker(error) => write!(formatter, "command run worker failed: {error}"),
            Self::CancellationWorker(error) => {
                write!(formatter, "command cancellation worker failed: {error}")
            }
            Self::Capacity => formatter.write_str("too many command runs are active"),
            Self::RunNotFound => formatter.write_str("command run not found"),
            Self::RunNotCancelable => formatter.write_str("command run is not cancelable"),
            Self::RuntimeUpdateRequired {
                running_release_id,
                selected_release_id,
            } => write!(
                formatter,
                "the Runtime was updated from release {running_release_id} to {selected_release_id}; reopen this Entry before starting new work"
            ),
            Self::RuntimeGenerationUnavailable(error) => {
                write!(
                    formatter,
                    "cannot determine the selected Runtime release: {error}"
                )
            }
            Self::ShuttingDown => formatter.write_str("the runtime service is shutting down"),
            Self::Start(error) => write!(formatter, "cannot start command execution: {error}"),
            Self::Journal(error) => {
                write!(formatter, "cannot start the command journal: {error}")
            }
            Self::Cancel(error) => write!(formatter, "cannot cancel command execution: {error}"),
            Self::RegistryUnavailable => formatter.write_str("command run registry is unavailable"),
        }
    }
}

impl std::error::Error for RuntimeServiceError {}
