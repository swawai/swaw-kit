use axum::{
    Json, Router,
    extract::State,
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use serde::Deserialize;

use crate::entry_manager::{EntryManager, EntryManagerError, EntryManagerErrorKind};

use super::{ServerState, api_error, command_run::runtime_service_error};

const CREATE_CONTROL: &str = "entry-instance-create";
const MIGRATE_CONTROL: &str = "entry-instance-migrate";
const CONTROL_HEADER: &str = "x-swawkit-control";

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct EntryInstanceRequest {
    entry_name: String,
}

pub(super) fn routes() -> Router<ServerState> {
    Router::new()
        .route("/api/v2/entries", get(get_entries).post(post_create))
        .route("/api/v2/entries/inspect", post(post_inspect))
        .route("/api/v2/entries/migrate", post(post_migrate))
}

async fn get_entries(State(state): State<ServerState>) -> Response {
    let context = state.context;
    match tokio::task::spawn_blocking(move || EntryManager::new(&context).inventory()).await {
        Ok(Ok(document)) => Json(document).into_response(),
        Ok(Err(error)) => entry_manager_error(error),
        Err(error) => worker_error("inventory", error),
    }
}

async fn post_inspect(
    State(state): State<ServerState>,
    Json(request): Json<EntryInstanceRequest>,
) -> Response {
    let context = state.context;
    match tokio::task::spawn_blocking(move || {
        EntryManager::new(&context).inspect(&request.entry_name)
    })
    .await
    {
        Ok(Ok(document)) => Json(document).into_response(),
        Ok(Err(error)) => entry_manager_error(error),
        Err(error) => worker_error("inspection", error),
    }
}

async fn post_create(
    State(state): State<ServerState>,
    headers: HeaderMap,
    Json(request): Json<EntryInstanceRequest>,
) -> Response {
    if !has_exact_control_header(&headers, CREATE_CONTROL) {
        return StatusCode::FORBIDDEN.into_response();
    }
    if let Err(error) = state.runtime_service.require_current_generation() {
        return runtime_service_error(error).into_response();
    }
    let context = state.context;
    match tokio::task::spawn_blocking(move || {
        EntryManager::new(&context).create(&request.entry_name)
    })
    .await
    {
        Ok(Ok(document)) => Json(document).into_response(),
        Ok(Err(error)) => entry_manager_error(error),
        Err(error) => worker_error("creation", error),
    }
}

async fn post_migrate(
    State(state): State<ServerState>,
    headers: HeaderMap,
    Json(request): Json<EntryInstanceRequest>,
) -> Response {
    if !has_exact_control_header(&headers, MIGRATE_CONTROL) {
        return StatusCode::FORBIDDEN.into_response();
    }
    if let Err(error) = state.runtime_service.require_current_generation() {
        return runtime_service_error(error).into_response();
    }
    let context = state.context;
    match tokio::task::spawn_blocking(move || {
        EntryManager::new(&context).migrate(&request.entry_name)
    })
    .await
    {
        Ok(Ok(document)) => Json(document).into_response(),
        Ok(Err(error)) => entry_manager_error(error),
        Err(error) => worker_error("migration", error),
    }
}

fn entry_manager_error(error: EntryManagerError) -> Response {
    let status = match error.kind() {
        EntryManagerErrorKind::InvalidName => StatusCode::UNPROCESSABLE_ENTITY,
        EntryManagerErrorKind::Conflict | EntryManagerErrorKind::Corrupt => StatusCode::CONFLICT,
        EntryManagerErrorKind::ManagerOnly => StatusCode::NOT_FOUND,
        EntryManagerErrorKind::Io => StatusCode::INTERNAL_SERVER_ERROR,
    };
    api_error(status, error.to_string()).into_response()
}

fn has_exact_control_header(headers: &HeaderMap, expected: &str) -> bool {
    let mut values = headers.get_all(CONTROL_HEADER).iter();
    values
        .next()
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| value == expected)
        && values.next().is_none()
}

fn worker_error(action: &str, error: tokio::task::JoinError) -> Response {
    api_error(
        StatusCode::INTERNAL_SERVER_ERROR,
        format!("Entry {action} worker failed: {error}"),
    )
    .into_response()
}
