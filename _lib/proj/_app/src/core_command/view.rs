use std::ffi::OsString;
use std::path::Path;

use swawkit_proj_protocol::FacetRoute;

use crate::{
    catalog::{CatalogSnapshot, CommandSpace},
    context::EntryContext,
    data_root::{DataRootSession, ResolveDataRootRequest},
    route_resolution::{CommandQuery, RouteResolutionError, RouteResolver},
    runtime_service::RuntimeService,
};

use super::{CoreCommandError, CoreCommandOutcome};

const VIEW_SOURCE_ADDRESS: &str = ".view/source";

pub fn execute(
    snapshot: &CatalogSnapshot,
    argv: &[OsString],
    context: &EntryContext,
    data_root: &Path,
) -> Result<Option<CoreCommandOutcome>, CoreCommandError> {
    let Some(route) = target(snapshot, argv)? else {
        return Ok(None);
    };
    let session = DataRootSession::new(ResolveDataRootRequest {
        swawkit_home: &context.swawkit_home,
        entry_file: &context.entry_file,
    })
    .map_err(|error| CoreCommandError::domain(format!("DataRoot resolution failed: {error}")))?;
    if session.resolved().path() != data_root {
        return Err(CoreCommandError::domain(
            "resolved DataRoot does not match the running Runtime",
        ));
    }
    let query = RuntimeService::native(context.clone(), session);
    resolve(snapshot, route, &query).map(Some)
}

pub(crate) fn execute_with_query(
    snapshot: &CatalogSnapshot,
    argv: &[OsString],
    query: &dyn CommandQuery,
) -> Result<Option<CoreCommandOutcome>, CoreCommandError> {
    let Some(route) = target(snapshot, argv)? else {
        return Ok(None);
    };
    resolve(snapshot, route, query).map(Some)
}

fn resolve(
    snapshot: &CatalogSnapshot,
    route: FacetRoute,
    query: &dyn CommandQuery,
) -> Result<CoreCommandOutcome, CoreCommandError> {
    let bundle = RouteResolver::new(snapshot, query)
        .resolve_view_bundle(&route)
        .map_err(route_error)?;
    let output = serde_json::to_string_pretty(&bundle).map_err(|error| {
        CoreCommandError::serialization("cannot serialize Web View Bundle", error)
    })?;
    Ok(CoreCommandOutcome::success(format!("{output}\n")))
}

fn target(
    snapshot: &CatalogSnapshot,
    argv: &[OsString],
) -> Result<Option<FacetRoute>, CoreCommandError> {
    let Some(address) = argv.first().and_then(|value| value.to_str()) else {
        return Ok(None);
    };
    if address != VIEW_SOURCE_ADDRESS {
        return Ok(None);
    }
    require_view_source_command(snapshot)?;
    let [_, route] = argv else {
        return Err(CoreCommandError::arguments(
            "usage: .view/source <FacetRoute>",
        ));
    };
    let route = route
        .to_str()
        .ok_or_else(|| CoreCommandError::arguments("FacetRoute is not valid Unicode"))?;
    FacetRoute::parse(route)
        .map(Some)
        .map_err(|error| CoreCommandError::arguments(error.to_string()))
}

fn require_view_source_command(snapshot: &CatalogSnapshot) -> Result<(), CoreCommandError> {
    if snapshot.commands.iter().any(|command| {
        command.space == CommandSpace::System
            && command.address == VIEW_SOURCE_ADDRESS
            && command.adapter.as_deref() == Some("core")
            && command.handler.as_deref() == Some("meta.view.source")
            && command.runnable
    }) {
        Ok(())
    } else {
        Err(CoreCommandError::domain("command not found: .view/source"))
    }
}

fn route_error(error: RouteResolutionError) -> CoreCommandError {
    match error {
        RouteResolutionError::NotFound(message) | RouteResolutionError::Invalid(message) => {
            CoreCommandError::arguments(message)
        }
        RouteResolutionError::Internal(message) => CoreCommandError::domain(message),
        RouteResolutionError::Runtime(error) => CoreCommandError::domain(error.to_string()),
    }
}

#[cfg(test)]
mod tests;
