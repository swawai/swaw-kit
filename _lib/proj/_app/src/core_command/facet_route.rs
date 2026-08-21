use std::ffi::OsString;
use std::path::Path;

use swawkit_proj_protocol::FacetRoute;

use crate::{
    catalog::CatalogSnapshot,
    context::EntryContext,
    data_root::{DataRootSession, ResolveDataRootRequest},
    route_resolution::{CommandQuery, ResolvedFacetCall, RouteResolutionError, RouteResolver},
    runtime_service::RuntimeService,
};

use super::{CoreCommandError, CoreCommandOutcome};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CliFacetRouteResolution {
    Document(CoreCommandOutcome),
    Invocation(Vec<OsString>),
}

pub fn resolve(
    snapshot: &CatalogSnapshot,
    argv: &[OsString],
    context: &EntryContext,
    data_root: &Path,
) -> Result<Option<CliFacetRouteResolution>, CoreCommandError> {
    if route_argument(argv).is_none() {
        return Ok(None);
    }
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
    resolve_with_query(snapshot, argv, &query)
}

pub(crate) fn resolve_with_query(
    snapshot: &CatalogSnapshot,
    argv: &[OsString],
    query: &dyn CommandQuery,
) -> Result<Option<CliFacetRouteResolution>, CoreCommandError> {
    let Some(route) = route_argument(argv) else {
        return Ok(None);
    };
    let route =
        FacetRoute::parse(route).map_err(|error| CoreCommandError::arguments(error.to_string()))?;
    let tail = argv.get(1..).unwrap_or_default();
    match RouteResolver::new(snapshot, query)
        .resolve_facet_call(&route)
        .map_err(route_error)?
    {
        ResolvedFacetCall::Document(document) => {
            if !tail.is_empty() {
                return Err(CoreCommandError::arguments(
                    "Collection and Projection Facets do not accept trailing arguments",
                ));
            }
            let output = serde_json::to_string_pretty(&document.value).map_err(|error| {
                CoreCommandError::serialization("cannot serialize Facet document", error)
            })?;
            Ok(Some(CliFacetRouteResolution::Document(
                CoreCommandOutcome::success(format!("{output}\n")),
            )))
        }
        ResolvedFacetCall::Invocation(invocation) => {
            if !invocation.accepts_tail && !tail.is_empty() {
                return Err(CoreCommandError::arguments(
                    "this Operation Facet does not accept trailing arguments",
                ));
            }
            let mut resolved = Vec::with_capacity(
                1 + invocation.arguments.len()
                    + if invocation.accepts_tail {
                        tail.len()
                    } else {
                        0
                    },
            );
            resolved.push(OsString::from(invocation.address));
            resolved.extend(invocation.arguments.into_iter().map(OsString::from));
            if invocation.accepts_tail {
                resolved.extend_from_slice(tail);
            }
            Ok(Some(CliFacetRouteResolution::Invocation(resolved)))
        }
    }
}

fn route_argument(argv: &[OsString]) -> Option<&str> {
    argv.first()
        .and_then(|address| address.to_str())
        .filter(|address| address.starts_with('$'))
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
