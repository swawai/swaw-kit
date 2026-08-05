use std::{
    io,
    net::{Ipv4Addr, SocketAddr},
    sync::Arc,
    thread,
};

use axum::{
    Json, Router,
    extract::{Request, State},
    http::{
        HeaderMap, HeaderName, HeaderValue, StatusCode,
        header::{CACHE_CONTROL, ETAG, HOST, IF_MATCH},
    },
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::get,
};
use serde::Serialize;
use tokio::{net::TcpListener, sync::oneshot};

use crate::{
    catalog::CatalogSnapshot,
    catalog_reader::CatalogReader,
    profile::{EntryProfileDocument, EntryProfileRecord, EntryProfileStore, ProfileUpdateError},
    web_assets,
};

#[derive(Clone)]
struct ServerState {
    catalog_reader: CatalogReader,
    profile_store: EntryProfileStore,
}

#[derive(Debug)]
pub enum ServerEvent {
    Ready(String),
    Stopped(Result<(), String>),
}

pub fn spawn<F>(
    catalog_reader: CatalogReader,
    profile_store: EntryProfileStore,
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
                    catalog_reader,
                    profile_store,
                    |url| notify(ServerEvent::Ready(url)),
                    shutdown,
                )),
                Err(error) => Err(error.to_string()),
            };

            let _ = notify(ServerEvent::Stopped(result));
        })
}

async fn run_server<F>(
    catalog_reader: CatalogReader,
    profile_store: EntryProfileStore,
    notify_ready: F,
    shutdown: oneshot::Receiver<()>,
) -> Result<(), String>
where
    F: FnOnce(String) -> Result<(), String>,
{
    let listener = bind_loopback().await.map_err(|error| error.to_string())?;
    let address = listener.local_addr().map_err(|error| error.to_string())?;
    let authority = address.to_string();
    let url = format!("http://{authority}/");

    notify_ready(url)?;

    axum::serve(listener, router(authority, catalog_reader, profile_store))
        .with_graceful_shutdown(async move {
            let _ = shutdown.await;
        })
        .await
        .map_err(|error| error.to_string())
}

async fn bind_loopback() -> io::Result<TcpListener> {
    TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).await
}

fn router(
    expected_authority: String,
    catalog_reader: CatalogReader,
    profile_store: EntryProfileStore,
) -> Router {
    Router::new()
        .route("/", get(web_assets::index))
        .route("/assets/{*path}", get(web_assets::asset))
        .route("/api/v2/catalog", get(get_catalog))
        .route("/api/v2/profile", get(get_profile).put(put_profile))
        .route("/healthz", get(health))
        .layer(middleware::from_fn(security_headers))
        .layer(middleware::from_fn_with_state(
            Arc::<str>::from(expected_authority),
            enforce_authority,
        ))
        .with_state(ServerState {
            catalog_reader,
            profile_store,
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
) -> Result<Json<CatalogSnapshot>, (StatusCode, &'static str)> {
    state.catalog_reader.read().await.map(Json).map_err(|_| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            "catalog discovery failed\n",
        )
    })
}

#[derive(Debug, Serialize)]
struct ApiError {
    error: String,
}

async fn get_profile(State(state): State<ServerState>) -> Response {
    profile_response(state.profile_store.document())
}

async fn put_profile(
    State(state): State<ServerState>,
    headers: HeaderMap,
    Json(profile): Json<EntryProfileRecord>,
) -> Result<Response, (StatusCode, Json<ApiError>)> {
    let expected_revision = expected_revision(&headers)?;
    match state
        .profile_store
        .replace_if_revision(expected_revision, profile)
    {
        Ok(document) => Ok(profile_response(document)),
        Err(ProfileUpdateError::Conflict { .. }) => Err(api_error(
            StatusCode::CONFLICT,
            "entry profile changed since it was loaded; reload before saving again",
        )),
        Err(ProfileUpdateError::Profile(error)) => Err(api_error(
            StatusCode::UNPROCESSABLE_ENTITY,
            error.to_string(),
        )),
    }
}

fn expected_revision(headers: &HeaderMap) -> Result<&str, (StatusCode, Json<ApiError>)> {
    let value = headers.get(IF_MATCH).ok_or_else(|| {
        api_error(
            StatusCode::PRECONDITION_REQUIRED,
            "If-Match with the loaded entry profile revision is required",
        )
    })?;
    let value = value.to_str().map_err(|_| {
        api_error(
            StatusCode::BAD_REQUEST,
            "If-Match must contain one strong entry profile revision",
        )
    })?;
    value
        .strip_prefix('"')
        .and_then(|value| value.strip_suffix('"'))
        .filter(|value| !value.is_empty() && !value.contains('"') && !value.contains(','))
        .ok_or_else(|| {
            api_error(
                StatusCode::BAD_REQUEST,
                "If-Match must contain one quoted strong entry profile revision",
            )
        })
}

fn profile_response(document: EntryProfileDocument) -> Response {
    let etag = HeaderValue::from_str(&format!("\"{}\"", document.revision))
        .expect("profile revisions are valid entity tags");
    ([(ETAG, etag)], Json(document)).into_response()
}

fn api_error(status: StatusCode, error: impl Into<String>) -> (StatusCode, Json<ApiError>) {
    (
        status,
        Json(ApiError {
            error: error.into(),
        }),
    )
}

async fn health() -> &'static str {
    "ok\n"
}

#[cfg(test)]
mod tests;
