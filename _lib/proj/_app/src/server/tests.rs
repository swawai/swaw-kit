use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};

use axum::{
    body::{Body, to_bytes},
    http::{Method, Request, header::CONTENT_TYPE},
};
use serde_json::{Value, json};
use tower::ServiceExt;

use super::*;
use crate::{
    context::EntryContext,
    data_root::{DataRootSession, ResolveDataRootRequest, resolve_data_root},
    profile::EntryProfileStore,
};

mod catalog;
mod command_run;
mod command_run_native;
mod entry_manager;
mod facet_resolution;
mod profile;
mod runtime;

const AUTHORITY: &str = "127.0.0.1:43127";
static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

fn test_host_runtime(context: &EntryContext) -> HostRuntimeDocument {
    let runtime =
        crate::host_runtime::HostRuntimeLocator::new(context).expect("locate test Host runtime");
    HostRuntimeDocument::new(
        runtime.instance_key().as_str(),
        &context.release_id,
        "test-host",
        std::process::id(),
        format!("http://{AUTHORITY}/"),
    )
    .expect("test Host runtime")
}

struct Fixture {
    root: PathBuf,
    release_id: String,
}

impl Fixture {
    fn new() -> Self {
        let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let root =
            std::env::temp_dir().join(format!("swawkit-server-{}-{sequence}", std::process::id()));
        let data_root = root.join("home/data/proj.swawkit");
        let runtime_root = data_root.join("runtime");
        fs::create_dir_all(runtime_root.join("releases")).expect("create fixture root");
        fs::create_dir_all(root.join("home/_lib/proj/system")).expect("create System root");
        fs::create_dir_all(root.join("home/_lib/proj/modules")).expect("create swaw Module root");
        let release_id = crate::runtime_release::tests::write_release(
            &root.join("home"),
            &runtime_root.join("releases"),
            &[
                ("swawkit-proj.exe", b"core"),
                ("swawkit-proj-host.exe", b"host"),
                ("swawkit-proj-module.exe", b"module"),
                ("swawkit-proj-dev.exe", b"dev"),
            ],
        );
        fs::write(runtime_root.join("current"), format!("{release_id}\n"))
            .expect("write Runtime selector");
        fs::write(root.join("home/swawkit.exe"), b"fixture").expect("create fixture entry");
        let fixture = Self { root, release_id };
        let context = fixture.context();
        resolve_data_root(ResolveDataRootRequest {
            swawkit_home: &context.swawkit_home,
            entry_file: &context.entry_file,
        })
        .expect("open fixture DataRoot");
        fixture
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

    fn context(&self) -> EntryContext {
        let data_root = self.root.join("home/data/proj.swawkit");
        EntryContext {
            swawkit_home: self.root.join("home"),
            data_root,
            runtime_root: self.root.join("home/data/proj.swawkit/runtime"),
            entry_file: self.root.join("home/swawkit.exe"),
            entry_name: "swawkit".to_owned(),
            invocation_directory: self.root.clone(),
            product_executable: self
                .root
                .join("home/data/proj.swawkit/runtime/releases")
                .join(&self.release_id)
                .join("swawkit-proj-host.exe"),
            release_id: self.release_id.clone(),
        }
    }

    fn data_root_session(&self) -> DataRootSession {
        let context = self.context();
        DataRootSession::new(ResolveDataRootRequest {
            swawkit_home: &context.swawkit_home,
            entry_file: &context.entry_file,
        })
        .expect("pin fixture Entry for DataRoot session")
    }

    fn profile_store(&self) -> EntryProfileStore {
        let data_root = self.root.join("home/data/proj.swawkit");
        fs::create_dir_all(&data_root).expect("create fixture DataRoot");
        EntryProfileStore::new(self.root.join("home"), data_root)
    }

    fn app(&self) -> Router {
        router(
            AUTHORITY.to_owned(),
            self.context(),
            self.data_root_session(),
        )
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

async fn send(app: Router, method: Method, path: &str, authority: Option<&str>) -> Response {
    let mut builder = Request::builder().method(method).uri(path);
    if let Some(authority) = authority {
        builder = builder.header(HOST, authority);
    }

    app.oneshot(builder.body(Body::empty()).expect("valid request"))
        .await
        .expect("router response")
}

async fn catalog_document(app: Router) -> Value {
    let response = send(app, Method::GET, "/api/v2/catalog", Some(AUTHORITY)).await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("catalog body");
    serde_json::from_slice(&body).expect("catalog JSON")
}

#[tokio::test]
async fn exposes_status_and_requires_explicit_authority_for_shutdown() {
    let fixture = Fixture::new();
    let app = fixture.app();

    let status = send(app.clone(), Method::GET, "/api/v2/host", Some(AUTHORITY)).await;
    assert_eq!(status.status(), StatusCode::OK);
    let body = to_bytes(status.into_body(), usize::MAX)
        .await
        .expect("Host status body");
    let document: Value = serde_json::from_slice(&body).expect("Host status JSON");
    assert_eq!(
        document["protocol"],
        crate::runtime_control::HOST_STATUS_PROTOCOL
    );
    assert_eq!(document["pid"], std::process::id());
    assert!(
        document["instanceKeySha256"]
            .as_str()
            .is_some_and(|value| value.len() == 64)
    );
    assert_eq!(document["runningReleaseId"], fixture.release_id);
    assert_eq!(document["selectedReleaseId"], fixture.release_id);
    assert_eq!(document["updateAvailable"], false);
    let fields = document
        .as_object()
        .expect("Host status object")
        .keys()
        .map(String::as_str)
        .collect::<std::collections::BTreeSet<_>>();
    assert_eq!(
        fields,
        std::collections::BTreeSet::from([
            "bootId",
            "instanceKeySha256",
            "pid",
            "protocol",
            "runningReleaseId",
            "selectedReleaseId",
            "updateAvailable",
            "url",
        ])
    );

    let unauthorized = send(
        app.clone(),
        Method::POST,
        "/api/v2/host/shutdown",
        Some(AUTHORITY),
    )
    .await;
    assert_eq!(unauthorized.status(), StatusCode::FORBIDDEN);

    let accepted = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/api/v2/host/shutdown")
                .header(HOST, AUTHORITY)
                .header("x-swawkit-control", "shutdown")
                .body(Body::empty())
                .expect("valid Host shutdown request"),
        )
        .await
        .expect("Host shutdown response");
    assert_eq!(accepted.status(), StatusCode::ACCEPTED);
}

#[tokio::test]
async fn restart_requires_explicit_authority_and_a_new_selected_release() {
    let fixture = Fixture::new();
    let app = fixture.app();

    let unauthorized = send(
        app.clone(),
        Method::POST,
        "/api/v2/host/restart",
        Some(AUTHORITY),
    )
    .await;
    assert_eq!(unauthorized.status(), StatusCode::FORBIDDEN);

    let current = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/api/v2/host/restart")
                .header(HOST, AUTHORITY)
                .header("x-swawkit-control", "restart")
                .body(Body::empty())
                .expect("valid Host restart request"),
        )
        .await
        .expect("Host restart response");
    assert_eq!(current.status(), StatusCode::CONFLICT);
}

#[tokio::test]
async fn serves_only_the_declared_local_surface() {
    let fixture = Fixture::new();
    fixture.directory("home/_lib/proj");
    let app = fixture.app();

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
    let index_html = String::from_utf8_lossy(&body);
    assert!(index_html.contains("Swaw Kit Proj"));
    assert!(index_html.contains("id=\"command-run-operation-list\""));
    assert!(index_html.contains("id=\"command-run-confirmation\""));
    assert!(index_html.contains("class=\"command-run-output\" id=\"command-run-output\""));
    assert!(index_html.contains("class=\"run-projection-output\" id=\"run-projection-output\""));
    assert!(index_html.contains("id=\"command-check-pane\""));
    assert!(index_html.contains("id=\"entry-manager-panel\""));

    for path in [
        "/commands",
        "/commands/module/project/proj/build/launcher",
        "/commands/system/dev/setup",
        "/commands/system/entry/language",
        "/commands/system/dev/rust/mode",
    ] {
        let response = send(app.clone(), Method::GET, path, Some(AUTHORITY)).await;
        assert_eq!(response.status(), StatusCode::OK, "{path}");
        assert_eq!(
            response.headers().get(CONTENT_TYPE),
            Some(&HeaderValue::from_static("text/html; charset=utf-8")),
            "{path}"
        );
    }

    for (path, content_type) in [
        ("/assets/app.css", "text/css; charset=utf-8"),
        ("/assets/styles/theme.css", "text/css; charset=utf-8"),
        ("/assets/styles/base.css", "text/css; charset=utf-8"),
        ("/assets/styles/shell.css", "text/css; charset=utf-8"),
        ("/assets/styles/explorer.css", "text/css; charset=utf-8"),
        ("/assets/styles/command-menu.css", "text/css; charset=utf-8"),
        ("/assets/styles/detail.css", "text/css; charset=utf-8"),
        (
            "/assets/styles/entry-profile.css",
            "text/css; charset=utf-8",
        ),
        (
            "/assets/styles/runtime-control.css",
            "text/css; charset=utf-8",
        ),
        ("/assets/styles/command-run.css", "text/css; charset=utf-8"),
        (
            "/assets/styles/run-projection.css",
            "text/css; charset=utf-8",
        ),
        (
            "/assets/styles/context-projection.css",
            "text/css; charset=utf-8",
        ),
        (
            "/assets/styles/command-check-projection.css",
            "text/css; charset=utf-8",
        ),
        (
            "/assets/styles/entry-manager.css",
            "text/css; charset=utf-8",
        ),
        ("/assets/app.js", "text/javascript; charset=utf-8"),
        ("/assets/i18n.js", "text/javascript; charset=utf-8"),
        (
            "/assets/command-identity.js",
            "text/javascript; charset=utf-8",
        ),
        ("/assets/catalog-model.js", "text/javascript; charset=utf-8"),
        ("/assets/facet-model.js", "text/javascript; charset=utf-8"),
        (
            "/assets/facet-resolution-client.js",
            "text/javascript; charset=utf-8",
        ),
        (
            "/assets/command-event-client.js",
            "text/javascript; charset=utf-8",
        ),
        ("/assets/navigation.js", "text/javascript; charset=utf-8"),
        ("/assets/explorer.js", "text/javascript; charset=utf-8"),
        (
            "/assets/explorer-model.js",
            "text/javascript; charset=utf-8",
        ),
        ("/assets/command-menu.js", "text/javascript; charset=utf-8"),
        (
            "/assets/command-menu-position.js",
            "text/javascript; charset=utf-8",
        ),
        ("/assets/detail.js", "text/javascript; charset=utf-8"),
        (
            "/assets/document-projection.js",
            "text/javascript; charset=utf-8",
        ),
        ("/assets/entry-profile.js", "text/javascript; charset=utf-8"),
        (
            "/assets/runtime-control.js",
            "text/javascript; charset=utf-8",
        ),
        (
            "/assets/command-run-client.js",
            "text/javascript; charset=utf-8",
        ),
        (
            "/assets/command-run-output.js",
            "text/javascript; charset=utf-8",
        ),
        (
            "/assets/command-run-model.js",
            "text/javascript; charset=utf-8",
        ),
        ("/assets/command-run.js", "text/javascript; charset=utf-8"),
        (
            "/assets/command-run-operations.js",
            "text/javascript; charset=utf-8",
        ),
        (
            "/assets/run-projection-model.js",
            "text/javascript; charset=utf-8",
        ),
        (
            "/assets/run-projection.js",
            "text/javascript; charset=utf-8",
        ),
        (
            "/assets/context-projection-model.js",
            "text/javascript; charset=utf-8",
        ),
        (
            "/assets/context-projection.js",
            "text/javascript; charset=utf-8",
        ),
        (
            "/assets/context-tray-model.js",
            "text/javascript; charset=utf-8",
        ),
        ("/assets/context-tray.js", "text/javascript; charset=utf-8"),
        (
            "/assets/command-check-projection-model.js",
            "text/javascript; charset=utf-8",
        ),
        (
            "/assets/command-check-projection.js",
            "text/javascript; charset=utf-8",
        ),
        (
            "/assets/subject-collection-model.js",
            "text/javascript; charset=utf-8",
        ),
        (
            "/assets/subject-explorer.js",
            "text/javascript; charset=utf-8",
        ),
        ("/assets/subject-facet.js", "text/javascript; charset=utf-8"),
        (
            "/assets/entry-manager-model.js",
            "text/javascript; charset=utf-8",
        ),
        (
            "/assets/entry-manager-client.js",
            "text/javascript; charset=utf-8",
        ),
        (
            "/assets/entry-manager-view.js",
            "text/javascript; charset=utf-8",
        ),
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
    assert_eq!(document["language"], "zh-CN");
    assert_eq!(document["commands"].as_array().map(Vec::len), Some(2));
    assert!(command(&document, "swaw").is_some());
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
        send(app.clone(), Method::GET, "/api/v1/profile", Some(AUTHORITY))
            .await
            .status(),
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        send(app, Method::GET, "/_lib/proj/run.ps1", Some(AUTHORITY))
            .await
            .status(),
        StatusCode::NOT_FOUND
    );
}

#[tokio::test]
async fn rejects_missing_or_foreign_host_headers() {
    let fixture = Fixture::new();
    fixture.directory("home/_lib/proj");
    let app = fixture.app();

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

fn command<'a>(document: &'a Value, address: &str) -> Option<&'a Value> {
    document["commands"]
        .as_array()?
        .iter()
        .find(|node| node["address"] == address)
}
