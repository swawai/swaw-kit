use std::{
    io,
    net::{Ipv4Addr, SocketAddr},
    sync::Arc,
    thread,
};

use axum::{
    extract::{Request, State},
    http::{
        header::{CACHE_CONTROL, HOST},
        HeaderName, HeaderValue, StatusCode,
    },
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::get,
    Json, Router,
};
use tokio::{net::TcpListener, sync::oneshot};

use crate::{catalog::CatalogSnapshot, catalog_reader::CatalogReader, web_assets};

#[derive(Debug)]
pub enum ServerEvent {
    Ready(String),
    Stopped(Result<(), String>),
}

pub fn spawn<F>(
    catalog_reader: CatalogReader,
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
    notify_ready: F,
    shutdown: oneshot::Receiver<()>,
) -> Result<(), String>
where
    F: FnOnce(String) -> Result<(), String>,
{
    let listener = bind_loopback().await.map_err(|error| error.to_string())?;
    let address = listener
        .local_addr()
        .map_err(|error| error.to_string())?;
    let authority = address.to_string();
    let url = format!("http://{authority}/");

    notify_ready(url)?;

    axum::serve(listener, router(authority, catalog_reader))
        .with_graceful_shutdown(async move {
            let _ = shutdown.await;
        })
        .await
        .map_err(|error| error.to_string())
}

async fn bind_loopback() -> io::Result<TcpListener> {
    TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).await
}

fn router(expected_authority: String, catalog_reader: CatalogReader) -> Router {
    Router::new()
        .route("/", get(web_assets::index))
        .route("/assets/{*path}", get(web_assets::asset))
        .route("/api/v1/catalog", get(get_catalog))
        .route("/healthz", get(health))
        .layer(middleware::from_fn(security_headers))
        .layer(middleware::from_fn_with_state(
            Arc::<str>::from(expected_authority),
            enforce_authority,
        ))
        .with_state(catalog_reader)
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
        return (
            StatusCode::MISDIRECTED_REQUEST,
            "misdirected request\n",
        )
            .into_response();
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
    State(catalog_reader): State<CatalogReader>,
) -> Result<Json<CatalogSnapshot>, (StatusCode, &'static str)> {
    catalog_reader
        .read()
        .await
        .map(Json)
        .map_err(|_| (StatusCode::INTERNAL_SERVER_ERROR, "catalog discovery failed\n"))
}

async fn health() -> &'static str {
    "ok\n"
}

#[cfg(test)]
mod tests;
