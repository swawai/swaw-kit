use std::{io, sync::Arc, thread};

use axum::{
    Json, Router,
    extract::{Path, Request, State},
    http::{
        HeaderMap, HeaderName, HeaderValue, StatusCode,
        header::{CACHE_CONTROL, ETAG, HOST, IF_MATCH},
    },
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::get,
};
use serde::{Deserialize, Serialize};
use tokio::sync::oneshot;

use crate::{
    catalog::CatalogSnapshot,
    catalog_reader::CatalogReader,
    context::EntryContext,
    data_root::DataRootSession,
    entry_config::{EntryConfigDocument, EntryConfigStore, EntryConfigUpdateError},
    host_runtime::{HostRuntimeDocument, HostRuntimeIdentity},
    runtime_service::RuntimeService,
    web_assets,
};

mod command_run;
mod entry_manager;
mod facet_resolution;
mod host_control;
mod loopback;
mod runtime_control;

use host_control::HostControl;

#[derive(Clone)]
struct ServerState {
    context: EntryContext,
    data_root: DataRootSession,
    runtime_service: RuntimeService,
    host_control: HostControl,
    host_runtime: HostRuntimeDocument,
}

#[derive(Debug)]
pub enum ServerEvent {
    Ready(HostRuntimeDocument),
    Stopped(Result<(), String>),
}

pub fn spawn<F>(
    context: EntryContext,
    data_root: DataRootSession,
    host_runtime: HostRuntimeIdentity,
    notify: F,
    shutdown: oneshot::Receiver<()>,
) -> io::Result<thread::JoinHandle<()>>
where
    F: Fn(ServerEvent) -> Result<(), String> + Send + 'static,
{
    thread::Builder::new()
        .name("swawkit-web".to_owned())
        .spawn(move || {
            let result = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(runtime) => runtime.block_on(run_server(
                    context,
                    data_root,
                    host_runtime,
                    |document| notify(ServerEvent::Ready(document)),
                    shutdown,
                )),
                Err(error) => Err(error.to_string()),
            };

            let _ = notify(ServerEvent::Stopped(result));
        })
}

async fn run_server<F>(
    context: EntryContext,
    data_root: DataRootSession,
    host_runtime: HostRuntimeIdentity,
    notify_ready: F,
    shutdown: oneshot::Receiver<()>,
) -> Result<(), String>
where
    F: FnOnce(HostRuntimeDocument) -> Result<(), String>,
{
    let listener = loopback::bind_browser_safe()
        .await
        .map_err(|error| error.to_string())?;
    let address = listener.local_addr().map_err(|error| error.to_string())?;
    let authority = address.to_string();
    let url = format!("http://{authority}/");
    let host_runtime = host_runtime
        .document(url)
        .map_err(|error| error.to_string())?;

    notify_ready(host_runtime.clone())?;

    let runtime_service = RuntimeService::native(context.clone(), data_root.clone());
    let host_control = HostControl::new();
    let shutdown_control = host_control.clone();
    let serve_result = axum::serve(
        listener,
        router_with_runtime_service(
            authority,
            context,
            data_root,
            runtime_service.clone(),
            host_runtime,
            host_control,
        ),
    )
    .with_graceful_shutdown(async move {
        tokio::select! {
            _ = shutdown => {}
            _ = shutdown_control.wait() => {}
        }
    })
    .await
    .map_err(|error| error.to_string());
    let shutdown_result = tokio::task::spawn_blocking(move || {
        runtime_service
            .shutdown()
            .map_err(|error| error.to_string())
    })
    .await
    .map_err(|error| format!("Runtime service shutdown task failed: {error}"))
    .and_then(|result| result);

    match (serve_result, shutdown_result) {
        (Ok(()), Ok(())) => Ok(()),
        (Err(error), Ok(())) | (Ok(()), Err(error)) => Err(error),
        (Err(serve_error), Err(shutdown_error)) => Err(format!("{serve_error}; {shutdown_error}")),
    }
}

#[cfg(test)]
fn router(expected_authority: String, context: EntryContext, data_root: DataRootSession) -> Router {
    let runtime =
        crate::host_runtime::HostRuntimeLocator::new(&context).expect("locate test Host runtime");
    let host_runtime = HostRuntimeDocument::new(
        runtime.instance_key().as_str(),
        &context.release_id,
        "test-host",
        std::process::id(),
        format!("http://{expected_authority}/"),
    )
    .expect("test Host runtime");
    let runtime_service = RuntimeService::native(context.clone(), data_root.clone());
    router_with_runtime_service(
        expected_authority,
        context,
        data_root,
        runtime_service,
        host_runtime,
        HostControl::new(),
    )
}

fn router_with_runtime_service(
    expected_authority: String,
    context: EntryContext,
    data_root: DataRootSession,
    runtime_service: RuntimeService,
    host_runtime: HostRuntimeDocument,
    host_control: HostControl,
) -> Router {
    let manager_routes = context.is_manager().then(entry_manager::routes);
    let mut router = Router::new()
        .route("/", get(web_assets::index))
        .route("/commands", get(web_assets::index))
        .route("/commands/{*path}", get(web_assets::index))
        .route("/assets/{*path}", get(web_assets::asset))
        .route("/api/v2/catalog", get(get_catalog))
        .route(
            "/api/v3/facet-resolutions",
            axum::routing::post(facet_resolution::post_facet_resolution),
        )
        .route(
            "/api/v3/view-bundles",
            axum::routing::post(facet_resolution::post_view_bundle),
        )
        .route("/api/v2/entry-config", get(get_entry_config))
        .route("/api/v2/host", get(host_control::get_host))
        .route("/api/v2/runtime", get(runtime_control::get_runtime))
        .route(
            "/api/v2/host/shutdown",
            axum::routing::post(host_control::post_shutdown),
        )
        .route(
            "/api/v2/host/restart",
            axum::routing::post(host_control::post_restart),
        )
        .route(
            "/api/v2/runtime/cleanup",
            axum::routing::post(runtime_control::post_cleanup),
        )
        .route(
            "/api/v3/command-runs",
            axum::routing::post(command_run::post_command_run),
        )
        .route(
            "/api/v3/command-runs/{id}",
            get(command_run::get_command_run).delete(command_run::delete_command_run),
        )
        .route(
            "/api/v2/entry-config/settings/{address}",
            axum::routing::put(put_entry_config_setting),
        )
        .route("/healthz", get(host_control::health));
    if let Some(routes) = manager_routes {
        router = router.merge(routes);
    }
    router
        .layer(middleware::from_fn(security_headers))
        .layer(middleware::from_fn_with_state(
            Arc::<str>::from(expected_authority),
            enforce_authority,
        ))
        .with_state(ServerState {
            context,
            data_root,
            runtime_service,
            host_control,
            host_runtime,
        })
}

async fn enforce_authority(
    State(expected_authority): State<Arc<str>>,
    request: Request,
    next: Next,
) -> Response {
    let matches = request
        .headers()
        .get(HOST)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| value.eq_ignore_ascii_case(&expected_authority));

    if !matches {
        return (StatusCode::MISDIRECTED_REQUEST, "misdirected request\n").into_response();
    }

    next.run(request).await
}

async fn security_headers(request: Request, next: Next) -> Response {
    let mut response = next.run(request).await;
    let headers = response.headers_mut();
    headers.insert(CACHE_CONTROL, HeaderValue::from_static("no-store"));
    headers.insert(
        HeaderName::from_static("content-security-policy"),
        HeaderValue::from_static(
            "default-src 'none'; script-src 'self'; connect-src 'self'; \
             style-src 'self'; img-src 'self'; \
             base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
        ),
    );
    headers.insert(
        HeaderName::from_static("x-content-type-options"),
        HeaderValue::from_static("nosniff"),
    );
    response
}

async fn get_catalog(
    State(state): State<ServerState>,
) -> Result<Json<CatalogSnapshot>, (StatusCode, Json<ApiError>)> {
    let config_store = entry_config_store(&state);
    CatalogReader::new(state.context, config_store)
        .read()
        .await
        .map(Json)
        .map_err(|_| {
            api_error(
                StatusCode::INTERNAL_SERVER_ERROR,
                "catalog discovery failed",
            )
        })
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ApiError {
    error: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    code: Option<&'static str>,
}

async fn get_entry_config(State(state): State<ServerState>) -> Response {
    let config_store = entry_config_store(&state);
    let document = match tokio::task::spawn_blocking(move || config_store.document()).await {
        Ok(document) => document,
        Err(error) => {
            return api_error(
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("Entry Config worker failed: {error}"),
            )
            .into_response();
        }
    };
    entry_config_response(document)
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct EntryConfigSettingUpdate {
    value: serde_json::Value,
}

async fn put_entry_config_setting(
    State(state): State<ServerState>,
    Path(address): Path<String>,
    headers: HeaderMap,
    Json(update): Json<EntryConfigSettingUpdate>,
) -> Result<Response, (StatusCode, Json<ApiError>)> {
    let expected_revision = expected_revision(&headers, "Entry Config")?.to_owned();
    let value = match update.value {
        serde_json::Value::String(value) => Some(value),
        serde_json::Value::Null => None,
        _ => {
            return Err(api_error(
                StatusCode::UNPROCESSABLE_ENTITY,
                "Entry Config setting value must be a string or null",
            ));
        }
    };
    state
        .runtime_service
        .require_current_generation()
        .map_err(command_run::runtime_service_error)?;
    let config_store = entry_config_store(&state);
    let update = tokio::task::spawn_blocking(move || {
        config_store.update_setting_if_revision(&expected_revision, &address, value)
    })
    .await
    .map_err(|error| {
        api_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("Entry Config worker failed: {error}"),
        )
    })?;
    match update {
        Ok(document) => Ok(entry_config_response(document)),
        Err(EntryConfigUpdateError::Conflict { .. }) => Err(api_error(
            StatusCode::CONFLICT,
            "Entry Config changed since it was loaded; reload before saving again",
        )),
        Err(EntryConfigUpdateError::Config(error)) => Err(api_error(
            StatusCode::UNPROCESSABLE_ENTITY,
            error.to_string(),
        )),
    }
}

fn expected_revision<'a>(
    headers: &'a HeaderMap,
    subject: &str,
) -> Result<&'a str, (StatusCode, Json<ApiError>)> {
    let value = headers.get(IF_MATCH).ok_or_else(|| {
        api_error(
            StatusCode::PRECONDITION_REQUIRED,
            format!("If-Match with the loaded {subject} revision is required"),
        )
    })?;
    let value = value.to_str().map_err(|_| {
        api_error(
            StatusCode::BAD_REQUEST,
            format!("If-Match must contain one strong {subject} revision"),
        )
    })?;
    value
        .strip_prefix('"')
        .and_then(|value| value.strip_suffix('"'))
        .filter(|value| !value.is_empty() && !value.contains('"') && !value.contains(','))
        .ok_or_else(|| {
            api_error(
                StatusCode::BAD_REQUEST,
                format!("If-Match must contain one quoted strong {subject} revision"),
            )
        })
}

fn entry_config_response(document: EntryConfigDocument) -> Response {
    let etag = HeaderValue::from_str(&format!("\"{}\"", document.revision))
        .expect("Entry Config revisions are valid entity tags");
    ([(ETAG, etag)], Json(document)).into_response()
}

fn api_error(status: StatusCode, error: impl Into<String>) -> (StatusCode, Json<ApiError>) {
    coded_api_error(status, error, None)
}

fn coded_api_error(
    status: StatusCode,
    error: impl Into<String>,
    code: Option<&'static str>,
) -> (StatusCode, Json<ApiError>) {
    (
        status,
        Json(ApiError {
            error: error.into(),
            code,
        }),
    )
}

fn entry_config_store(state: &ServerState) -> EntryConfigStore {
    let resolved = state.data_root.resolved();
    EntryConfigStore::new(&state.context.swawkit_home, resolved.path())
}

#[cfg(test)]
mod tests;
