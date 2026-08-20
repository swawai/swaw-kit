use axum::{
    Json,
    extract::{Path, RawQuery, State},
    http::{HeaderValue, StatusCode, header::LOCATION},
    response::{IntoResponse, Response},
};
use serde::Deserialize;

use crate::run_journal::RunJournalSource;
use crate::runtime_service::{RuntimeServiceError, StartCommandRunRequest};

use super::{ServerState, api_error};

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct StartCommandRunBody {
    address: String,
    #[serde(default)]
    arguments: Vec<String>,
}

pub(super) async fn post_command_run(
    State(state): State<ServerState>,
    Json(body): Json<StartCommandRunBody>,
) -> Response {
    let request = StartCommandRunRequest {
        address: body.address,
        arguments: body.arguments,
        source: RunJournalSource::Web,
    };
    match state.runtime_service.submit(request).await {
        Ok(document) => {
            let location = HeaderValue::from_str(&format!("/api/v2/command-runs/{}", document.id))
                .expect("command run identifiers are valid Location values");
            (StatusCode::CREATED, [(LOCATION, location)], Json(document)).into_response()
        }
        Err(error) => runtime_service_error(error).into_response(),
    }
}

pub(super) async fn get_command_run(
    State(state): State<ServerState>,
    Path(id): Path<String>,
    RawQuery(query): RawQuery,
) -> Response {
    let after = match parse_after(query.as_deref()) {
        Ok(after) => after,
        Err(error) => return api_error(StatusCode::BAD_REQUEST, error).into_response(),
    };
    match state.runtime_service.read(&id, after) {
        Ok(document) => Json(document).into_response(),
        Err(error) => runtime_service_error(error).into_response(),
    }
}

pub(super) async fn delete_command_run(
    State(state): State<ServerState>,
    Path(id): Path<String>,
) -> Response {
    match state.runtime_service.cancel(id).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(error) => runtime_service_error(error).into_response(),
    }
}

fn parse_after(query: Option<&str>) -> Result<u64, &'static str> {
    let Some(query) = query.filter(|query| !query.is_empty()) else {
        return Ok(0);
    };
    let value = query
        .strip_prefix("after=")
        .filter(|value| !value.is_empty() && !value.contains('&'))
        .ok_or("the command run query accepts only one 'after' cursor")?;
    value
        .parse()
        .map_err(|_| "the command run 'after' cursor must be an unsigned integer")
}

fn runtime_service_error(error: RuntimeServiceError) -> (StatusCode, Json<super::ApiError>) {
    let status = match &error {
        RuntimeServiceError::InvalidRequest(_)
        | RuntimeServiceError::ProfileInvalid(_)
        | RuntimeServiceError::CommandInvalid(_)
        | RuntimeServiceError::LifecycleCommandUnsupported => StatusCode::UNPROCESSABLE_ENTITY,
        RuntimeServiceError::ProfileSetupRequired
        | RuntimeServiceError::DependenciesNotReady(_)
        | RuntimeServiceError::RunNotCancelable => StatusCode::CONFLICT,
        RuntimeServiceError::CommandNotFound | RuntimeServiceError::RunNotFound => {
            StatusCode::NOT_FOUND
        }
        RuntimeServiceError::Capacity => StatusCode::TOO_MANY_REQUESTS,
        RuntimeServiceError::ShuttingDown => StatusCode::SERVICE_UNAVAILABLE,
        RuntimeServiceError::CatalogDiscovery
        | RuntimeServiceError::ExecutionContext(_)
        | RuntimeServiceError::CommandDataRoot(_)
        | RuntimeServiceError::PreparationWorker(_)
        | RuntimeServiceError::RunWorker(_)
        | RuntimeServiceError::CancellationWorker(_)
        | RuntimeServiceError::Start(_)
        | RuntimeServiceError::Journal(_)
        | RuntimeServiceError::Cancel(_)
        | RuntimeServiceError::RegistryUnavailable
        | RuntimeServiceError::Query(_)
        | RuntimeServiceError::Shutdown(_) => StatusCode::INTERNAL_SERVER_ERROR,
    };
    let message = match error {
        RuntimeServiceError::LifecycleCommandUnsupported => {
            "in-process System lifecycle commands cannot run through the Web command API".to_owned()
        }
        RuntimeServiceError::ShuttingDown => "the Runtime service is shutting down".to_owned(),
        error => error.to_string(),
    };
    api_error(status, message)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preserves_web_error_text_at_the_http_boundary() {
        let (_, Json(lifecycle)) =
            runtime_service_error(RuntimeServiceError::LifecycleCommandUnsupported);
        assert_eq!(
            lifecycle.error,
            "in-process System lifecycle commands cannot run through the Web command API"
        );

        let (_, Json(shutdown)) = runtime_service_error(RuntimeServiceError::ShuttingDown);
        assert_eq!(shutdown.error, "the Runtime service is shutting down");

        let (status, Json(non_cancelable)) =
            runtime_service_error(RuntimeServiceError::RunNotCancelable);
        assert_eq!(status, StatusCode::CONFLICT);
        assert_eq!(non_cancelable.error, "command run is not cancelable");
    }
}
