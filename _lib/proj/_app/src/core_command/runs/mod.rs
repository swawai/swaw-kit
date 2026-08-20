use std::ffi::{OsStr, OsString};
use std::path::Path;

use crate::catalog::{CatalogSnapshot, CommandSpace};
use crate::command_journal::{CommandJournalAccess, CommandLocator};
use crate::context::EntryContext;
use crate::profile::EntryProfileState;

use super::{CoreCommandError, CoreCommandOutcome};

mod query;
mod render;

const RUNS_ADDRESS: &str = ".runs";
const ALL_RUNS_FACET: &str = "all";
const MAX_LATEST_RANGE: usize = 32;
const RUNS_FACET: &str = "runs";
const RUN_KIND: &str = "run";

pub fn execute(
    snapshot: &CatalogSnapshot,
    argv: &[OsString],
    context: &EntryContext,
    data_root: &Path,
    profile_state: &EntryProfileState,
) -> Result<Option<CoreCommandOutcome>, CoreCommandError> {
    let Some(address) = argv.first().and_then(|value| value.to_str()) else {
        return Ok(None);
    };
    if address != RUNS_ADDRESS {
        return Ok(None);
    }
    require_runs_command(snapshot)?;

    let output = match argv.get(1..) {
        Some([]) => render::global_history(&query::run_collection(
            snapshot,
            context,
            data_root,
            profile_state,
        )?)?,
        Some([option]) if option == "--json" => render::json(&query::run_collection(
            snapshot,
            context,
            data_root,
            profile_state,
        )?)?,
        Some([option, target]) if option == "--json" => {
            render::json(&query::command_run_collection(
                snapshot,
                context,
                data_root,
                profile_state,
                unicode_argument(target, "command locator")?,
            )?)?
        }
        Some([option, id]) if option == "--run" => render::json(&query::global_run(
            snapshot,
            context,
            data_root,
            profile_state,
            unicode_argument(id, "run id")?,
            0,
        )?)?,
        Some([option, id, cursor_option, cursor])
            if option == "--run" && cursor_option == "--after" =>
        {
            render::json(&query::global_run(
                snapshot,
                context,
                data_root,
                profile_state,
                unicode_argument(id, "run id")?,
                render::parse_after_cursor(cursor)?,
            )?)?
        }
        Some([option, id]) if option == "--open" => {
            let id = unicode_argument(id, "run id")?;
            query::global_run_access(snapshot, context, data_root, profile_state, id)?
                .open_run_directory(id)
                .map_err(|error| CoreCommandError::io("cannot open command journal", error))?
                .display()
                .to_string()
        }
        _ => return execute_for_command(snapshot, argv, context, data_root, profile_state),
    };
    Ok(Some(CoreCommandOutcome::success(format!("{output}\n"))))
}

fn execute_for_command(
    snapshot: &CatalogSnapshot,
    argv: &[OsString],
    context: &EntryContext,
    data_root: &Path,
    profile_state: &EntryProfileState,
) -> Result<Option<CoreCommandOutcome>, CoreCommandError> {
    let target = argv
        .get(1)
        .ok_or_else(runs_usage)
        .and_then(|value| unicode_argument(value, "command address"))?;
    let locator = CommandLocator::from_cli_target(snapshot, target)
        .map_err(|error| CoreCommandError::domain(error.to_string()))?;
    let journal =
        CommandJournalAccess::resolve(context, data_root, profile_state, snapshot, locator)
            .map_err(|error| CoreCommandError::domain(error.to_string()))?;

    let output = match argv.get(2..) {
        Some([]) => render::numbered_history(&journal.history().map_err(query::journal_error)?)?,
        Some([option, selector]) if option == "--latest" => {
            let selector =
                render::parse_latest_selector(unicode_argument(selector, "latest selector")?)?;
            if selector.start == selector.end {
                render::json(
                    &journal
                        .latest_run(selector.start)
                        .map_err(query::journal_error)?,
                )?
            } else {
                render::json(
                    &journal
                        .latest_runs(selector.start, selector.end)
                        .map_err(query::journal_error)?,
                )?
            }
        }
        Some([option, id]) if option == "--run" => render::json(
            &journal
                .run(unicode_argument(id, "run id")?, 0)
                .map_err(query::journal_error)?,
        )?,
        Some([option, id, cursor_option, cursor])
            if option == "--run" && cursor_option == "--after" =>
        {
            render::json(
                &journal
                    .run(
                        unicode_argument(id, "run id")?,
                        render::parse_after_cursor(cursor)?,
                    )
                    .map_err(query::journal_error)?,
            )?
        }
        Some([option, id]) if option == "--open" => journal
            .open_run_directory(unicode_argument(id, "run id")?)
            .map_err(|error| CoreCommandError::io("cannot open command journal", error))?
            .display()
            .to_string(),
        _ => return Err(runs_usage()),
    };
    Ok(Some(CoreCommandOutcome::success(format!("{output}\n"))))
}

fn require_runs_command(snapshot: &CatalogSnapshot) -> Result<(), CoreCommandError> {
    if snapshot.commands.iter().any(|command| {
        command.space == CommandSpace::System
            && command.address == RUNS_ADDRESS
            && command.adapter.as_deref() == Some("core")
            && command.handler.as_deref() == Some("meta.runs")
            && command.runnable
    }) {
        Ok(())
    } else {
        Err(CoreCommandError::domain("command not found: .runs"))
    }
}

fn runs_usage() -> CoreCommandError {
    CoreCommandError::arguments(
        "usage: .runs [--json [<command-locator>] | --run <run-id> [--after <cursor>] | --open <run-id>] | .runs <command-address> [--latest <n|n..m> | --run <run-id> [--after <cursor>] | --open <run-id>]",
    )
}

fn unicode_argument<'a>(argument: &'a OsStr, name: &str) -> Result<&'a str, CoreCommandError> {
    argument
        .to_str()
        .ok_or_else(|| CoreCommandError::arguments(format!("{name} is not valid Unicode")))
}

#[cfg(test)]
mod tests;
