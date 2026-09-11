use std::collections::BTreeSet;
use std::io;
use std::path::Path;

use crate::catalog::{CatalogSnapshot, CommandSpace, command_for_resource_route};
use crate::command_journal::{CommandJournalAccess, CommandLocator, RunJournalDocument};
use swawkit_proj_protocol::{
    FacetRoute, ResourceIdentity, ResourceList, ResourceListing, ResourceRoute,
};

use super::{RUN_KIND, RUNS_ADDRESS, RUNS_FACET};
use crate::core_command::CoreCommandError;

pub(super) fn run_collection(
    snapshot: &CatalogSnapshot,
    data_root: &Path,
) -> Result<ResourceList, CoreCommandError> {
    let (kind, facet_ids) = run_kind_contract(snapshot)?;
    let source = kind.clone();
    let mut runs = Vec::new();
    for (locator, journal) in all_journals(snapshot, data_root)? {
        for run in journal.runs().map_err(journal_error)? {
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
    let resources = runs
        .into_iter()
        .map(|(_, locator, run)| {
            if !seen.insert(run.id.clone()) {
                return Err(CoreCommandError::domain(format!(
                    "run id '{}' is ambiguous across command journals",
                    run.id
                )));
            }
            let route = source
                .resource()
                .child(source.facet(), &run.id)
                .map_err(protocol_error)?;
            ResourceListing::new(
                ResourceIdentity::instance(kind.clone(), run.id.clone()).map_err(protocol_error)?,
                run.id,
                route,
                facet_ids.clone(),
                super::render::format_timestamp(run.started_at_unix_ms),
                run_summary(&locator, run.state, run.source, run.event_count),
            )
            .map_err(protocol_error)
        })
        .collect::<Result<Vec<_>, CoreCommandError>>()?;
    ResourceList::new(source, resources).map_err(protocol_error)
}

pub(super) fn command_run_collection(
    snapshot: &CatalogSnapshot,
    data_root: &Path,
    target: &str,
) -> Result<ResourceList, CoreCommandError> {
    let (kind, facet_ids) = run_kind_contract(snapshot)?;
    let route = ResourceRoute::parse(target)
        .map_err(|error| CoreCommandError::domain(error.to_string()))?;
    let command = command_for_resource_route(snapshot, &route).ok_or_else(|| {
        CoreCommandError::domain(format!(
            "Resource Route '{route}' does not identify a Command Resource"
        ))
    })?;
    let locator = CommandLocator::parse(&command.address)
        .map_err(|error| CoreCommandError::domain(error.to_string()))?;
    let source = FacetRoute::new(route, RUNS_FACET).map_err(protocol_error)?;
    let locator_label = locator.to_string();
    let journal = CommandJournalAccess::resolve(data_root, snapshot, locator)
        .map_err(|error| CoreCommandError::domain(error.to_string()))?;
    let resources = journal
        .runs()
        .map_err(journal_error)?
        .into_iter()
        .take(32)
        .map(|run| {
            let resource_route = source
                .resource()
                .child(source.facet(), &run.id)
                .map_err(protocol_error)?;
            ResourceListing::new(
                ResourceIdentity::instance(kind.clone(), run.id.clone()).map_err(protocol_error)?,
                run.id,
                resource_route,
                facet_ids.clone(),
                super::render::format_timestamp(run.started_at_unix_ms),
                run_summary(&locator_label, run.state, run.source, run.event_count),
            )
            .map_err(protocol_error)
        })
        .collect::<Result<Vec<_>, CoreCommandError>>()?;
    ResourceList::new(source, resources).map_err(protocol_error)
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

fn run_kind_contract(
    snapshot: &CatalogSnapshot,
) -> Result<(FacetRoute, Vec<String>), CoreCommandError> {
    let owner = snapshot
        .commands
        .iter()
        .find(|command| {
            command.space == CommandSpace::System
                && command.address == RUNS_ADDRESS
                && command.alias_of.is_none()
        })
        .ok_or_else(|| CoreCommandError::domain("Run Resource Kind owner is unavailable"))?;
    let kind = owner
        .resource_kinds
        .iter()
        .find(|kind| kind.kind == RUN_KIND)
        .ok_or_else(|| CoreCommandError::domain("Run Resource Kind is unavailable"))?;
    Ok((
        kind.source.clone(),
        kind.facets.iter().map(|facet| facet.id.clone()).collect(),
    ))
}

fn protocol_error(error: impl std::fmt::Display) -> CoreCommandError {
    CoreCommandError::domain(error.to_string())
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
