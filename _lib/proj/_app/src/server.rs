use std::{
    io,
    net::{Ipv4Addr, SocketAddr},
    sync::Arc,
    thread,
};

use axum::{
    extract::{Request, State},
    http::{
        header::{CACHE_CONTROL, CONTENT_TYPE, HOST},
        HeaderName, HeaderValue, StatusCode,
    },
    middleware::{self, Next},
    response::{Html, IntoResponse, Response},
    routing::get,
    Router,
};
use tokio::{net::TcpListener, sync::oneshot};

const INDEX_HTML: &str = include_str!("../web/index.html");
const APP_CSS: &str = include_str!("../web/app.css");

#[derive(Debug)]
pub enum ServerEvent {
    Ready(String),
    Stopped(Result<(), String>),
}

pub fn spawn<F>(
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
                    |url| notify(ServerEvent::Ready(url)),
                    shutdown,
                )),
                Err(error) => Err(error.to_string()),
            };

            let _ = notify(ServerEvent::Stopped(result));
        })
}

async fn run_server<F>(
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

    axum::serve(listener, router(authority))
        .with_graceful_shutdown(async move {
            let _ = shutdown.await;
        })
        .await
        .map_err(|error| error.to_string())
}

async fn bind_loopback() -> io::Result<TcpListener> {
    TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).await
}

fn router(expected_authority: String) -> Router {
    Router::new()
        .route("/", get(index))
        .route("/assets/app.css", get(styles))
        .route("/healthz", get(health))
        .layer(middleware::from_fn(security_headers))
        .layer(middleware::from_fn_with_state(
            Arc::<str>::from(expected_authority),
            enforce_authority,
        ))
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
            "default-src 'none'; style-src 'self'; img-src 'self'; \
             base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
        ),
    );
    headers.insert(
        HeaderName::from_static("x-content-type-options"),
        HeaderValue::from_static("nosniff"),
    );
    response
}

async fn index() -> Html<&'static str> {
    Html(INDEX_HTML)
}

async fn styles() -> impl IntoResponse {
    ([(CONTENT_TYPE, "text/css; charset=utf-8")], APP_CSS)
}

async fn health() -> &'static str {
    "ok\n"
}

#[cfg(test)]
mod tests {
    use std::{
        io::{Read, Write},
        net::TcpStream,
        sync::mpsc,
        time::Duration,
    };

    use axum::{
        body::{to_bytes, Body},
        http::{Method, Request},
    };
    use tower::ServiceExt;

    use super::*;

    const AUTHORITY: &str = "127.0.0.1:43127";

    async fn send(method: Method, path: &str, authority: Option<&str>) -> Response {
        let mut builder = Request::builder().method(method).uri(path);
        if let Some(authority) = authority {
            builder = builder.header(HOST, authority);
        }

        router(AUTHORITY.to_owned())
            .oneshot(builder.body(Body::empty()).expect("valid request"))
            .await
            .expect("router response")
    }

    #[tokio::test]
    async fn serves_only_the_initial_read_only_surface() {
        let index = send(Method::GET, "/", Some(AUTHORITY)).await;
        assert_eq!(index.status(), StatusCode::OK);
        assert_eq!(
            index.headers().get(CACHE_CONTROL),
            Some(&HeaderValue::from_static("no-store"))
        );
        assert_eq!(
            index
                .headers()
                .get(HeaderName::from_static("x-content-type-options")),
            Some(&HeaderValue::from_static("nosniff"))
        );
        let body = to_bytes(index.into_body(), usize::MAX)
            .await
            .expect("index body");
        assert!(String::from_utf8_lossy(&body).contains("Swaw Kit Proj"));

        assert_eq!(
            send(Method::GET, "/assets/app.css", Some(AUTHORITY))
                .await
                .status(),
            StatusCode::OK
        );
        assert_eq!(
            send(Method::GET, "/healthz", Some(AUTHORITY))
                .await
                .status(),
            StatusCode::OK
        );
        assert_eq!(
            send(Method::POST, "/", Some(AUTHORITY)).await.status(),
            StatusCode::METHOD_NOT_ALLOWED
        );
        assert_eq!(
            send(Method::GET, "/api/v1/run", Some(AUTHORITY))
                .await
                .status(),
            StatusCode::NOT_FOUND
        );
        assert_eq!(
            send(Method::GET, "/_lib/proj/run.ps1", Some(AUTHORITY))
                .await
                .status(),
            StatusCode::NOT_FOUND
        );
    }

    #[tokio::test]
    async fn rejects_missing_or_foreign_host_headers() {
        assert_eq!(
            send(Method::GET, "/", None).await.status(),
            StatusCode::MISDIRECTED_REQUEST
        );
        assert_eq!(
            send(Method::GET, "/", Some("attacker.example"))
                .await
                .status(),
            StatusCode::MISDIRECTED_REQUEST
        );
    }

    #[tokio::test]
    async fn binds_independent_random_ports_on_ipv4_loopback() {
        let first = bind_loopback().await.expect("first listener");
        let second = bind_loopback().await.expect("second listener");
        let first_address = first.local_addr().expect("first address");
        let second_address = second.local_addr().expect("second address");

        assert_eq!(first_address.ip(), Ipv4Addr::LOCALHOST);
        assert_eq!(second_address.ip(), Ipv4Addr::LOCALHOST);
        assert_ne!(first_address.port(), 0);
        assert_ne!(second_address.port(), 0);
        assert_ne!(first_address.port(), second_address.port());
    }

    #[test]
    fn shutdown_signal_stops_the_live_http_server() {
        let (events, received_events) = mpsc::channel();
        let (shutdown, shutdown_receiver) = oneshot::channel();
        let server_thread = spawn(
            move |event| events.send(event).map_err(|error| error.to_string()),
            shutdown_receiver,
        )
        .expect("server thread");

        let ready = received_events
            .recv_timeout(Duration::from_secs(5))
            .expect("ready event");
        let ServerEvent::Ready(url) = ready else {
            panic!("expected ready event");
        };
        let authority = url
            .strip_prefix("http://")
            .and_then(|value| value.strip_suffix('/'))
            .expect("loopback URL");

        let mut stream = TcpStream::connect(authority).expect("HTTP connection");
        write!(
            stream,
            "GET /healthz HTTP/1.1\r\nHost: {authority}\r\nConnection: close\r\n\r\n"
        )
        .expect("HTTP request");
        let mut response = String::new();
        stream
            .read_to_string(&mut response)
            .expect("HTTP response");
        assert!(response.starts_with("HTTP/1.1 200 OK\r\n"));
        assert!(response.ends_with("\r\nok\n"));

        shutdown.send(()).expect("shutdown signal");
        let stopped = received_events
            .recv_timeout(Duration::from_secs(5))
            .expect("stopped event");
        assert!(matches!(stopped, ServerEvent::Stopped(Ok(()))));
        server_thread.join().expect("clean server thread");
    }
}
