use std::ffi::OsString;
use std::path::PathBuf;

use crate::catalog::{CatalogSnapshot, CommandAdapter, CommandSpace};
use crate::command::ResolvedCommand;
use crate::context::EntryContext;
use crate::profile::{EntryProfileState, EntryProfileStore};

use super::{CoreCommandError, CoreCommandOutcome, check, help, profile, runs};

/// An owned in-process command invocation.
///
/// Construction validates only the Catalog execution identity. Argument
/// parsing, reads, and mutations remain in `execute`, so a Runtime can create
/// its Journal before the command performs observable work.
pub(crate) enum PreparedCoreCommand {
    Help {
        snapshot: CatalogSnapshot,
        argv: Vec<OsString>,
    },
    Check {
        snapshot: CatalogSnapshot,
        argv: Vec<OsString>,
        context: EntryContext,
        data_root: PathBuf,
    },
    Runs {
        snapshot: CatalogSnapshot,
        argv: Vec<OsString>,
        context: EntryContext,
        data_root: PathBuf,
        profile_state: EntryProfileState,
    },
    ProfileSetting {
        address: String,
        argv: Vec<OsString>,
        store: EntryProfileStore,
    },
}

impl PreparedCoreCommand {
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn for_runtime(
        command: &ResolvedCommand,
        argv: Vec<OsString>,
        snapshot: CatalogSnapshot,
        context: EntryContext,
        data_root: PathBuf,
        profile_state: EntryProfileState,
        profile_store: EntryProfileStore,
    ) -> Result<Self, CoreCommandError> {
        if command.adapter != CommandAdapter::Core || command.space != CommandSpace::System {
            return Err(CoreCommandError::domain(format!(
                "Catalog invariant failed for '{}': in-process command is not a System Core command",
                command.address
            )));
        }
        if command
            .path
            .first()
            .is_some_and(|segment| matches!(segment.as_str(), "entry" | "runtime"))
        {
            return Err(CoreCommandError::domain(format!(
                "lifecycle command '{}' cannot run through the Runtime command service",
                command.address
            )));
        }

        match command.handler.as_deref() {
            Some("meta.help") => Ok(Self::Help { snapshot, argv }),
            Some("meta.check") => Ok(Self::Check {
                snapshot,
                argv,
                context,
                data_root,
            }),
            Some("meta.runs") => Ok(Self::Runs {
                snapshot,
                argv,
                context,
                data_root,
                profile_state,
            }),
            Some("entry.profile.set") => Ok(Self::ProfileSetting {
                address: command.address.clone(),
                argv,
                store: profile_store,
            }),
            Some(handler) => Err(CoreCommandError::domain(format!(
                "unsupported Runtime Core command handler: {handler}"
            ))),
            None => Err(CoreCommandError::domain(format!(
                "Catalog invariant failed for '{}': Core command has no handler",
                command.address
            ))),
        }
    }

    pub(crate) fn execute(self) -> Result<CoreCommandOutcome, CoreCommandError> {
        match self {
            Self::Help { snapshot, argv } => required(help::execute(&snapshot, &argv), ".help"),
            Self::Check {
                snapshot,
                argv,
                context,
                data_root,
            } => required(
                check::execute(&snapshot, &argv, &context, &data_root),
                ".check",
            ),
            Self::Runs {
                snapshot,
                argv,
                context,
                data_root,
                profile_state,
            } => required(
                runs::execute(&snapshot, &argv, &context, &data_root, &profile_state),
                ".runs",
            ),
            Self::ProfileSetting {
                address,
                argv,
                store,
            } => profile::set(&address, argv.get(1..).unwrap_or_default(), &store),
        }
    }
}

fn required(
    outcome: Result<Option<CoreCommandOutcome>, CoreCommandError>,
    address: &str,
) -> Result<CoreCommandOutcome, CoreCommandError> {
    outcome?.ok_or_else(|| {
        CoreCommandError::domain(format!(
            "Catalog invariant failed: {address} Core handler did not accept its invocation"
        ))
    })
}

#[cfg(test)]
mod tests;
