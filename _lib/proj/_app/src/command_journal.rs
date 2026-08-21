use std::error::Error;
use std::fmt;
use std::io;
use std::mem::size_of;
use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};

use windows_sys::Win32::UI::{
    Shell::{SEE_MASK_FLAG_NO_UI, SEE_MASK_NOASYNC, SHELLEXECUTEINFOW, ShellExecuteExW},
    WindowsAndMessaging::SW_SHOWNORMAL,
};

use crate::{
    catalog::CatalogSnapshot,
    command::catalog_command_data_root,
    run_journal::{read_run, read_run_directory, read_run_history},
};

pub use crate::run_journal::{RunJournalDocument, RunJournalHistoryDocument};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunRecord {
    pub id: String,
    pub source: &'static str,
    pub state: &'static str,
    pub started_at_unix_ms: u64,
    pub event_count: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandLocator {
    address: String,
}

impl CommandLocator {
    pub fn parse(value: impl Into<String>) -> Result<Self, CommandJournalAccessError> {
        let address = value.into();
        if address.is_empty() || address.contains('\0') {
            return Err(CommandJournalAccessError::InvalidLocator(
                "the command locator must contain one canonical command address".to_owned(),
            ));
        }
        Ok(Self { address })
    }

    pub fn address(&self) -> &str {
        &self.address
    }

    pub fn from_cli_target(
        catalog: &CatalogSnapshot,
        target: &str,
    ) -> Result<Self, CommandJournalAccessError> {
        let command = catalog
            .commands
            .iter()
            .find(|command| command.address == target)
            .ok_or(CommandJournalAccessError::CommandNotFound)?;
        Ok(Self {
            address: command.address.clone(),
        })
    }
}

impl fmt::Display for CommandLocator {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.address)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CommandJournalAccessError {
    InvalidLocator(String),
    CommandNotFound,
    CatalogInvariant(String),
}

impl fmt::Display for CommandJournalAccessError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidLocator(message) | Self::CatalogInvariant(message) => {
                formatter.write_str(message)
            }
            Self::CommandNotFound => formatter.write_str("command not found"),
        }
    }
}

impl Error for CommandJournalAccessError {}

#[derive(Debug, Clone)]
pub struct CommandJournalAccess {
    address: String,
    module_data_root: PathBuf,
}

impl CommandJournalAccess {
    pub fn resolve(
        data_root: &Path,
        catalog: &CatalogSnapshot,
        locator: CommandLocator,
    ) -> Result<Self, CommandJournalAccessError> {
        let command = catalog
            .commands
            .iter()
            .find(|command| command.address == locator.address)
            .ok_or(CommandJournalAccessError::CommandNotFound)?;
        let module_data_root = catalog_command_data_root(data_root, command)
            .map_err(|error| CommandJournalAccessError::CatalogInvariant(error.to_string()))?;
        Ok(Self {
            address: locator.address,
            module_data_root,
        })
    }

    pub fn history(&self) -> io::Result<RunJournalHistoryDocument> {
        read_run_history(&self.module_data_root, &self.address)
    }

    pub fn runs(&self) -> io::Result<Vec<RunRecord>> {
        self.history().map(|history| {
            history
                .into_runs()
                .into_iter()
                .map(|run| RunRecord {
                    id: run.id,
                    source: match run.source {
                        crate::run_journal::RunJournalSource::Cli => "CLI",
                        crate::run_journal::RunJournalSource::Web => "Web",
                    },
                    state: match run.state {
                        crate::run_journal::RunJournalStatus::Running => "running",
                        crate::run_journal::RunJournalStatus::Exited => "exited",
                        crate::run_journal::RunJournalStatus::Canceled => "canceled",
                        crate::run_journal::RunJournalStatus::Failed => "failed",
                    },
                    started_at_unix_ms: run.started_at_unix_ms,
                    event_count: run.event_count,
                })
                .collect()
        })
    }

    pub fn run(&self, id: &str, after: u64) -> io::Result<RunJournalDocument> {
        read_run(&self.module_data_root, &self.address, id, after)
    }

    pub fn latest_run(&self, ordinal: usize) -> io::Result<RunJournalDocument> {
        self.latest_runs(ordinal, ordinal)?
            .pop()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "command journal not found"))
    }

    pub fn latest_runs(
        &self,
        start_ordinal: usize,
        end_ordinal: usize,
    ) -> io::Result<Vec<RunJournalDocument>> {
        let start_index = start_ordinal.checked_sub(1).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "latest ordinal must begin at one",
            )
        })?;
        if end_ordinal < start_ordinal {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "latest ordinal range is reversed",
            ));
        }
        let history = self.history()?;
        let mut ids = Vec::with_capacity(end_ordinal - start_ordinal + 1);
        for index in start_index..end_ordinal {
            ids.push(history.run_id_at(index).ok_or_else(|| {
                io::Error::new(io::ErrorKind::NotFound, "command journal not found")
            })?);
        }
        ids.into_iter().map(|id| self.run(&id, 0)).collect()
    }

    pub fn run_directory(&self, id: &str) -> io::Result<PathBuf> {
        read_run_directory(&self.module_data_root, &self.address, id)
    }

    pub fn open_run_directory(&self, id: &str) -> io::Result<PathBuf> {
        let path = self.run_directory(id)?;
        open_directory(&path)?;
        Ok(path)
    }
}

fn open_directory(path: &Path) -> io::Result<()> {
    let verb = "open".encode_utf16().chain(Some(0)).collect::<Vec<_>>();
    let path = path
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect::<Vec<_>>();
    let mut request = SHELLEXECUTEINFOW {
        cbSize: size_of::<SHELLEXECUTEINFOW>() as u32,
        fMask: SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI,
        lpVerb: verb.as_ptr(),
        lpFile: path.as_ptr(),
        nShow: SW_SHOWNORMAL,
        ..Default::default()
    };
    if unsafe { ShellExecuteExW(&mut request) } == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::catalog::CommandSpace;

    #[test]
    fn locator_is_the_canonical_cli_address() {
        assert_eq!(
            CommandLocator::parse(".dev/status").unwrap(),
            CommandLocator {
                address: ".dev/status".to_owned(),
            }
        );
        assert_eq!(
            CommandLocator::parse("project/build").unwrap().to_string(),
            "project/build"
        );
        for invalid in ["", "bad\0address"] {
            assert!(CommandLocator::parse(invalid).is_err(), "{invalid}");
        }
    }

    #[test]
    fn cli_targets_require_an_exact_catalog_address() {
        fn command(
            address: &str,
            space: CommandSpace,
            namespace: Option<&str>,
            path: &[&str],
        ) -> crate::catalog::CommandNode {
            crate::catalog::CommandNode {
                address: address.to_owned(),
                space,
                namespace: namespace.map(str::to_owned),
                path: path.iter().map(|value| (*value).to_owned()).collect(),
                parent: None,
                alias_of: None,
                runnable: true,
                entry: Some("run.exe".to_owned()),
                adapter: Some("exe".to_owned()),
                handler: None,
                product: None,
                requirements: Vec::new(),
                provisions: Vec::new(),
                delegate_owner: None,
                declares_native: false,
                declared_facets: Vec::new(),
                declared_resource_kinds: Vec::new(),
                help: None,
                resource_kinds: Vec::new(),
                facets: Vec::new(),
                diagnostic: None,
                authored_resource: true,
                help_diagnostic: None,
                directory: PathBuf::new(),
                executor_directory: PathBuf::new(),
                native_owner: None,
            }
        }

        let catalog = CatalogSnapshot {
            protocol: "fixture",
            entry_name: "swawkit".to_owned(),
            language: "en",
            commands: vec![
                command(
                    ".dev/status",
                    CommandSpace::System,
                    None,
                    &["dev", "status"],
                ),
                command(
                    "project/build",
                    CommandSpace::Module,
                    Some("project"),
                    &["build"],
                ),
            ],
        };
        assert_eq!(
            CommandLocator::from_cli_target(&catalog, ".dev/status")
                .unwrap()
                .to_string(),
            ".dev/status"
        );
        assert_eq!(
            CommandLocator::from_cli_target(&catalog, "project/build")
                .unwrap()
                .to_string(),
            "project/build"
        );
        assert_eq!(
            CommandLocator::from_cli_target(&catalog, "module/project/build"),
            Err(CommandJournalAccessError::CommandNotFound),
            "the internal Module space must not become a CLI prefix"
        );
    }
}
