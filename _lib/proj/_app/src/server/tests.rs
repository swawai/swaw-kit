use std::{
    fs,
    io::{Read, Write},
    net::TcpStream,
    path::PathBuf,
    sync::{
        atomic::{AtomicU64, Ordering},
        mpsc,
    },
    time::Duration,
};

use axum::{
    body::{to_bytes, Body},
    http::{header::CONTENT_TYPE, Method, Request},
};
use serde_json::{json, Value};
use tower::ServiceExt;

use super::*;
use crate::context::AppContext;

const AUTHORITY: &str = "127.0.0.1:43127";
static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    root: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "swawkit-server-{}-{sequence}",
            std::process::id()
        ));
        fs::create_dir_all(&root).expect("create fixture root");
        Self { root }
    }

    fn directory(&self, relative: &str) -> PathBuf {
        let path = self.root.join(relative);
        fs::create_dir_all(&path).expect("create fixture directory");
        path
    }

    fn file(&self, relative: &str, text: &str) {
        let path = self.root.join(relative);
        fs::create_dir_all(path.parent().expect("fixture file parent"))
            .expect("create fixture file parent");
        fs::write(path, text).expect("write fixture file");
    }

    fn reader(&self) -> CatalogReader {
        CatalogReader::new(AppContext {
            proj_home: self.root.join("home"),
            project_root: self.root.join("project"),
            action_root: self.root.join("project/.swaw"),
            entry_name: "swawkit".to_owned(),
        })
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

async fn send(
    app: Router,
    method: Method,
    path: &str,
    authority: Option<&str>,
) -> Response {
    let mut builder = Request::builder().method(method).uri(path);
    if let Some(authority) = authority {
        builder = builder.header(HOST, authority);
    }

    app.oneshot(builder.body(Body::empty()).expect("valid request"))
        .await
        .expect("router response")
}

async fn catalog_document(app: Router) -> Value {
    let response = send(app, Method::GET, "/api/v1/catalog", Some(AUTHORITY)).await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("catalog body");
    serde_json::from_slice(&body).expect("catalog JSON")
}

#[tokio::test]
async fn serves_only_the_initial_read_only_surface() {
    let fixture = Fixture::new();
    fixture.directory("home/_lib/proj");
    let app = router(AUTHORITY.to_owned(), fixture.reader());

    let index = send(app.clone(), Method::GET, "/", Some(AUTHORITY)).await;
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
    assert_eq!(
        index.headers().get(CONTENT_TYPE),
        Some(&HeaderValue::from_static("text/html; charset=utf-8"))
    );
    let body = to_bytes(index.into_body(), usize::MAX)
        .await
        .expect("index body");
    assert!(String::from_utf8_lossy(&body).contains("Swaw Kit Proj"));

    for (path, content_type) in [
        ("/assets/app.css", "text/css; charset=utf-8"),
        ("/assets/styles/theme.css", "text/css; charset=utf-8"),
        ("/assets/styles/base.css", "text/css; charset=utf-8"),
        ("/assets/styles/shell.css", "text/css; charset=utf-8"),
        ("/assets/styles/explorer.css", "text/css; charset=utf-8"),
        ("/assets/styles/detail.css", "text/css; charset=utf-8"),
        ("/assets/app.js", "text/javascript; charset=utf-8"),
        (
            "/assets/catalog-model.js",
            "text/javascript; charset=utf-8",
        ),
        ("/assets/explorer.js", "text/javascript; charset=utf-8"),
        ("/assets/detail.js", "text/javascript; charset=utf-8"),
        ("/assets/system.js", "text/javascript; charset=utf-8"),
    ] {
        let response = send(app.clone(), Method::GET, path, Some(AUTHORITY)).await;
        assert_eq!(response.status(), StatusCode::OK, "{path}");
        assert_eq!(
            response.headers().get(CONTENT_TYPE),
            Some(&HeaderValue::from_static(content_type)),
            "{path}"
        );
    }
    assert_eq!(
        send(
            app.clone(),
            Method::GET,
            "/assets/not-published.js",
            Some(AUTHORITY)
        )
        .await
        .status(),
        StatusCode::NOT_FOUND
    );

    let document = catalog_document(app.clone()).await;
    assert_eq!(document["protocol"], crate::catalog::CATALOG_PROTOCOL);
    assert_eq!(document["entryName"], "swawkit");
    assert_eq!(document["commands"].as_array().map(Vec::len), Some(1));
    assert_eq!(
        send(app.clone(), Method::GET, "/healthz", Some(AUTHORITY))
            .await
            .status(),
        StatusCode::OK
    );
    assert_eq!(
        send(app.clone(), Method::POST, "/", Some(AUTHORITY))
            .await
            .status(),
        StatusCode::METHOD_NOT_ALLOWED
    );
    assert_eq!(
        send(app.clone(), Method::GET, "/api/v1/run", Some(AUTHORITY))
            .await
            .status(),
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        send(
            app,
            Method::GET,
            "/_lib/proj/run.ps1",
            Some(AUTHORITY)
        )
        .await
        .status(),
        StatusCode::NOT_FOUND
    );
}

#[tokio::test]
async fn rescans_the_catalog_on_each_request() {
    let fixture = Fixture::new();
    fixture.directory("home/_lib/proj");
    let app = router(AUTHORITY.to_owned(), fixture.reader());

    let before = catalog_document(app.clone()).await;
    assert!(command(&before, ".dynamic").is_none());

    fixture.file("home/_lib/proj/.dynamic/run.ps1", "");
    let after = catalog_document(app).await;
    assert_eq!(
        command(&after, ".dynamic").and_then(|node| node["runnable"].as_bool()),
        Some(true)
    );
}

#[tokio::test]
async fn returns_a_safe_error_when_catalog_discovery_fails() {
    let fixture = Fixture::new();
    let response = send(
        router(AUTHORITY.to_owned(), fixture.reader()),
        Method::GET,
        "/api/v1/catalog",
        Some(AUTHORITY),
    )
    .await;

    assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
    let body = to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("error body");
    assert_eq!(&body[..], b"catalog discovery failed\n");
}

#[tokio::test]
async fn serializes_the_complete_catalog_node_contract() {
    let fixture = Fixture::new();
    fixture.directory("home/_lib/proj");
    fixture.file("home/_lib/proj/.dev/status/run.cmd", "");
    fixture.file(
        "home/_lib/proj/.dev/status/_help/zh-CN.txt",
        "Show {{ADDRESS}}\nUse {{INVOCATION}}",
    );
    fixture.file("home/_lib/proj/.help/run.ps1", "");
    fixture.file("home/_lib/proj/.h/run.ps1", "");
    fixture.file("home/_lib/proj/.broken/run.ps1", "");
    fixture.file("home/_lib/proj/.broken/run.cmd", "");

    let document = catalog_document(router(AUTHORITY.to_owned(), fixture.reader())).await;
    assert_eq!(
        command(&document, ".dev").expect("group node"),
        &json!({
            "address": ".dev",
            "source": "kernel",
            "parent": "",
            "aliasOf": null,
            "runnable": false,
            "entry": null,
            "adapter": null,
            "help": null,
            "diagnostic": null
        })
    );
    assert_eq!(
        command(&document, ".dev.status").expect("runnable node"),
        &json!({
            "address": ".dev.status",
            "source": "kernel",
            "parent": ".dev",
            "aliasOf": null,
            "runnable": true,
            "entry": "run.cmd",
            "adapter": "cmd",
            "help": {
                "summary": "Show .dev.status",
                "text": "Show .dev.status\nUse swawkit .dev.status"
            },
            "diagnostic": null
        })
    );
    assert_eq!(
        command(&document, ".h").and_then(|node| node["aliasOf"].as_str()),
        Some(".help")
    );
    assert!(command(&document, ".broken")
        .and_then(|node| node["diagnostic"].as_str())
        .is_some_and(|message| message.contains("multiple run entries")));
    assert!(document["commands"]
        .as_array()
        .expect("commands array")
        .iter()
        .all(|node| node.get("directory").is_none()));
}

#[tokio::test]
async fn rejects_missing_or_foreign_host_headers() {
    let fixture = Fixture::new();
    fixture.directory("home/_lib/proj");
    let app = router(AUTHORITY.to_owned(), fixture.reader());

    assert_eq!(
        send(app.clone(), Method::GET, "/", None).await.status(),
        StatusCode::MISDIRECTED_REQUEST
    );
    assert_eq!(
        send(app, Method::GET, "/", Some("attacker.example"))
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
    let fixture = Fixture::new();
    fixture.directory("home/_lib/proj");
    let (events, received_events) = mpsc::channel();
    let (shutdown, shutdown_receiver) = oneshot::channel();
    let server_thread = spawn(
        fixture.reader(),
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

fn command<'a>(document: &'a Value, address: &str) -> Option<&'a Value> {
    document["commands"]
        .as_array()?
        .iter()
        .find(|node| node["address"] == address)
}
