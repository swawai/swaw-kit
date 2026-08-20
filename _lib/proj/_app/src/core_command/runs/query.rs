use std::collections::BTreeSet;
use std::io;
use std::path::Path;

use crate::catalog::{CatalogSnapshot, CommandSpace};
use crate::command_journal::{CommandJournalAccess, CommandLocator, RunJournalDocument};
use crate::subject::{SUBJECT_COLLECTION_PROTOCOL, SubjectCollection, SubjectRef, SubjectSummary};

use super::{ALL_RUNS_FACET, RUN_KIND, RUNS_ADDRESS, RUNS_FACET};
use crate::core_command::CoreCommandError;

pub(super) fn run_collection(
    snapshot: &CatalogSnapshot,
    data_root: &Path,
) -> Result<SubjectCollection, CoreCommandError> {
    let facet_ids = run_facet_ids(snapshot)?;
    let mut runs = Vec::new();
    for (locator, journal) in all_journals(snapshot, data_root)? {
        for run in journal.subject_runs().map_err(journal_error)? {
            runs.push((run.started_at_unix_ms, locator.clone(), run));
        }
    }
    runs.sort_by(|left, right| {
        right
            .0
            .cmp(&left.0)
            .then_with(|| right.2.id.cmp(&left.2.id))
    });
    runs.truncate(32);

    let mut seen = BTreeSet::new();
    let subjects = runs
        .into_iter()
        .map(|(_, locator, run)| {
            if !seen.insert(run.id.clone()) {
                return Err(CoreCommandError::domain(format!(
                    "run id '{}' is ambiguous across command journals",
                    run.id
                )));
            }
            Ok(SubjectSummary {
                reference: SubjectRef::Instance {
                    kind: RUN_KIND.to_owned(),
                    id: run.id,
                },
                label: super::render::format_timestamp(run.started_at_unix_ms),
                summary: run_summary(&locator, run.state, run.source, run.event_count),
                facet_ids: facet_ids.clone(),
            })
        })
        .collect::<Result<Vec<_>, CoreCommandError>>()?;
    Ok(SubjectCollection {
        protocol: SUBJECT_COLLECTION_PROTOCOL.to_owned(),
        owner: SubjectRef::Command {
            space: CommandSpace::System,
            namespace: None,
            address: RUNS_ADDRESS.to_owned(),
        },
        facet: ALL_RUNS_FACET.to_owned(),
        subjects,
    })
}

pub(super) fn command_run_collection(
    snapshot: &CatalogSnapshot,
    data_root: &Path,
    target: &str,
) -> Result<SubjectCollection, CoreCommandError> {
    let facet_ids = run_facet_ids(snapshot)?;
    let locator = CommandLocator::from_cli_target(snapshot, target)
        .map_err(|error| CoreCommandError::domain(error.to_string()))?;
    let command = snapshot
        .commands
        .iter()
        .find(|command| command.address == locator.address())
        .ok_or_else(|| CoreCommandError::domain("command not found"))?;
    let owner = SubjectRef::Command {
        space: command.space,
        namespace: command.namespace.clone(),
        address: locator.address().to_owned(),
    };
    let locator_label = locator.to_string();
    let journal = CommandJournalAccess::resolve(data_root, snapshot, locator)
        .map_err(|error| CoreCommandError::domain(error.to_string()))?;
    let subjects = journal
        .subject_runs()
        .map_err(journal_error)?
        .into_iter()
        .take(32)
        .map(|run| SubjectSummary {
            reference: SubjectRef::Instance {
                kind: RUN_KIND.to_owned(),
                id: run.id,
            },
            label: super::render::format_timestamp(run.started_at_unix_ms),
            summary: run_summary(&locator_label, run.state, run.source, run.event_count),
            facet_ids: facet_ids.clone(),
        })
        .collect();
    Ok(SubjectCollection {
        protocol: SUBJECT_COLLECTION_PROTOCOL.to_owned(),
        owner,
        facet: RUNS_FACET.to_owned(),
        subjects,
    })
}

pub(super) fn global_run(
    snapshot: &CatalogSnapshot,
    data_root: &Path,
    id: &str,
    after: u64,
) -> Result<RunJournalDocument, CoreCommandError> {
    global_run_access(snapshot, data_root, id)?
        .run(id, after)
        .map_err(journal_error)
}

pub(super) fn global_run_access(
    snapshot: &CatalogSnapshot,
    data_root: &Path,
    id: &str,
) -> Result<CommandJournalAccess, CoreCommandError> {
    let mut found = None;
    for (_, journal) in all_journals(snapshot, data_root)? {
        match journal.run_directory(id) {
            Ok(_) if found.is_some() => {
                return Err(CoreCommandError::domain(format!(
                    "run id '{id}' is ambiguous across command journals"
                )));
            }
            Ok(_) => found = Some(journal),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(journal_error(error)),
        }
    }
    found.ok_or_else(|| {
        journal_error(io::Error::new(
            io::ErrorKind::NotFound,
            "command journal not found",
        ))
    })
}

fn run_facet_ids(snapshot: &CatalogSnapshot) -> Result<Vec<String>, CoreCommandError> {
    let owner = snapshot
        .commands
        .iter()
        .find(|command| {
            command.space == CommandSpace::System
                && command.address == RUNS_ADDRESS
                && command.alias_of.is_none()
        })
        .ok_or_else(|| CoreCommandError::domain("Run Subject owner command is unavailable"))?;
    let kind = owner
        .subject_kinds
        .iter()
        .find(|kind| kind.kind == RUN_KIND)
        .ok_or_else(|| CoreCommandError::domain("Run Subject kind is unavailable"))?;
    Ok(kind.facets.iter().map(|facet| facet.id.clone()).collect())
}

fn all_journals(
    snapshot: &CatalogSnapshot,
    data_root: &Path,
) -> Result<Vec<(String, CommandJournalAccess)>, CoreCommandError> {
    snapshot
        .commands
        .iter()
        .filter(|command| {
            !command.is_control() && !command.address.is_empty() && command.alias_of.is_none()
        })
        .map(|command| {
            let locator = command.address.clone();
            let journal = CommandJournalAccess::resolve(
                data_root,
                snapshot,
                CommandLocator::parse(&locator)
                    .map_err(|error| CoreCommandError::domain(error.to_string()))?,
            )
            .map_err(|error| CoreCommandError::domain(error.to_string()))?;
            Ok((locator, journal))
        })
        .collect()
}

pub(super) fn journal_error(error: io::Error) -> CoreCommandError {
    CoreCommandError::io("cannot read command journal", error)
}

pub(super) fn run_summary(locator: &str, state: &str, source: &str, event_count: u64) -> String {
    format!("{locator} · {state} · {source} · {event_count} events")
}
