use axum::{
    Json,
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Response},
};
use serde::Deserialize;
use swawkit_proj_protocol::FacetRoute;

use crate::{
    catalog::CatalogSnapshot,
    entry_config::EntryConfigStore,
    route_resolution::{RouteResolutionError, RouteResolver},
    runtime_service::{RuntimeService, RuntimeServiceError},
};

use super::{ServerState, api_error, command_run::runtime_service_error};

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct RouteResolutionRequest {
    route: String,
}

struct ResolutionContext {
    catalog: CatalogSnapshot,
    runtime_service: RuntimeService,
}

type ApiResult<T> = Result<T, (StatusCode, Json<super::ApiError>)>;

pub(super) async fn post_facet_resolution(
    State(state): State<ServerState>,
    Json(request): Json<RouteResolutionRequest>,
) -> Response {
    let route = match FacetRoute::parse(&request.route) {
        Ok(route) => route,
        Err(error) => {
            return api_error(StatusCode::UNPROCESSABLE_ENTITY, error.to_string()).into_response();
        }
    };
    let resolution = match resolution_context(&state).await {
        Ok(resolution) => resolution,
        Err(error) => return error.into_response(),
    };
    match tokio::task::spawn_blocking(move || {
        RouteResolver::new(&resolution.catalog, &resolution.runtime_service)
            .resolve_document(&route)
    })
    .await
    {
        Ok(Ok(document)) => Json(document.value).into_response(),
        Ok(Err(error)) => resolution_error(error).into_response(),
        Err(error) => api_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("facet resolution worker failed: {error}"),
        )
        .into_response(),
    }
}

pub(super) async fn post_view_bundle(
    State(state): State<ServerState>,
    Json(request): Json<RouteResolutionRequest>,
) -> Response {
    let route = match FacetRoute::parse(&request.route) {
        Ok(route) => route,
        Err(error) => {
            return api_error(StatusCode::UNPROCESSABLE_ENTITY, error.to_string()).into_response();
        }
    };
    let resolution = match resolution_context(&state).await {
        Ok(resolution) => resolution,
        Err(error) => return error.into_response(),
    };
    match tokio::task::spawn_blocking(move || {
        RouteResolver::new(&resolution.catalog, &resolution.runtime_service)
            .resolve_view_bundle(&route)
    })
    .await
    {
        Ok(Ok(bundle)) => Json(bundle).into_response(),
        Ok(Err(error)) => resolution_error(error).into_response(),
        Err(error) => api_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("view bundle worker failed: {error}"),
        )
        .into_response(),
    }
}

async fn resolution_context(state: &ServerState) -> ApiResult<ResolutionContext> {
    let resolved = state.data_root.resolved();
    let entry = state.context.clone();
    let runtime_service = state.runtime_service.clone();
    let data_root = resolved.path().to_path_buf();
    tokio::task::spawn_blocking(move || {
        let config_state = EntryConfigStore::new(&entry.swawkit_home, &data_root).read();
        let catalog = CatalogSnapshot::discover(&entry, config_state.ready()).map_err(|_| {
            api_error(
                StatusCode::INTERNAL_SERVER_ERROR,
                "catalog discovery failed",
            )
        })?;
        Ok(ResolutionContext {
            catalog,
            runtime_service,
        })
    })
    .await
    .map_err(|error| {
        api_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("facet resolution worker failed: {error}"),
        )
    })?
}

fn resolution_error(error: RouteResolutionError) -> (StatusCode, Json<super::ApiError>) {
    match error {
        RouteResolutionError::NotFound(message) => api_error(StatusCode::NOT_FOUND, message),
        RouteResolutionError::Invalid(message) => {
            api_error(StatusCode::UNPROCESSABLE_ENTITY, message)
        }
        RouteResolutionError::Internal(message) => {
            api_error(StatusCode::INTERNAL_SERVER_ERROR, message)
        }
        RouteResolutionError::Runtime(
            error @ (RuntimeServiceError::RuntimeUpdateRequired { .. }
            | RuntimeServiceError::RuntimeGenerationUnavailable(_)),
        ) => runtime_service_error(error),
        RouteResolutionError::Runtime(_) => api_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "facet resolver command failed",
        ),
    }
}
