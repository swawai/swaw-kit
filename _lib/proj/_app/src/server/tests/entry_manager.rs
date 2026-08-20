use std::fs;

use axum::{
    Router,
    body::{Body, to_bytes},
    http::{Method, Request, StatusCode},
};
use serde_json::{Value, json};
use tower::ServiceExt;

use super::{AUTHORITY, Fixture};
use crate::{
    context::EntryContext,
    data_root::{DataRootSession, ResolveDataRootRequest},
    entry::EntryId,
};

const CONTROL_HEADER: &str = "x-swawkit-control";

async fn request(
    app: Router,
    method: Method,
    path: &str,
    body: Value,
    control: Option<&str>,
) -> axum::response::Response {
    let mut builder = Request::builder()
        .method(method)
        .uri(path)
        .header(axum::http::header::HOST, AUTHORITY)
        .header(axum::http::header::CONTENT_TYPE, "application/json");
    if let Some(control) = control {
        builder = builder.header(CONTROL_HEADER, control);
    }
    app.oneshot(
        builder
            .body(Body::from(
                serde_json::to_vec(&body).expect("serialize request"),
            ))
            .expect("valid request"),
    )
    .await
    .expect("router response")
}

async fn document(response: axum::response::Response) -> Value {
    let body = to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("response body");
    serde_json::from_slice(&body).expect("response JSON")
}

#[tokio::test]
async fn manager_inventory_and_inspection_use_the_frozen_wire() {
    let fixture = Fixture::new();
    let app = fixture.app();

    let inventory = super::send(app.clone(), Method::GET, "/api/v2/entries", Some(AUTHORITY)).await;
    assert_eq!(inventory.status(), StatusCode::OK);
    let inventory = document(inventory).await;
    assert_eq!(
        inventory.as_object().unwrap().keys().collect::<Vec<_>>(),
        ["entries", "protocol", "swawkitHome"]
    );
    assert_eq!(inventory["protocol"], "swawkit.entry-inventory/v1");
    assert_eq!(
        inventory["swawkitHome"],
        fixture.root.join("home").to_string_lossy().as_ref()
    );
    assert_eq!(inventory["entries"], json!([]));

    let inspection = request(
        app.clone(),
        Method::POST,
        "/api/v2/entries/inspect",
        json!({"entryName": "proj1"}),
        None,
    )
    .await;
    assert_eq!(inspection.status(), StatusCode::OK);
    let inspection = document(inspection).await;
    assert_eq!(
        inspection.as_object().unwrap().keys().collect::<Vec<_>>(),
        ["entry", "protocol"]
    );
    assert_eq!(inspection["protocol"], "swawkit.entry-instance-state/v1");
    assert_eq!(inspection["entry"]["entryName"], "proj1");
    assert_eq!(inspection["entry"]["status"], "available");
    assert_eq!(inspection["entry"]["entryId"], Value::Null);
    assert_eq!(inspection["entry"]["releaseId"], Value::Null);

    let invalid_name = request(
        app.clone(),
        Method::POST,
        "/api/v2/entries/inspect",
        json!({"entryName": "Proj1"}),
        None,
    )
    .await;
    assert_eq!(invalid_name.status(), StatusCode::UNPROCESSABLE_ENTITY);

    let unknown_field = request(
        app,
        Method::POST,
        "/api/v2/entries/inspect",
        json!({"entryName": "proj1", "mode": "guess"}),
        None,
    )
    .await;
    assert_eq!(unknown_field.status(), StatusCode::UNPROCESSABLE_ENTITY);
}

#[tokio::test]
async fn create_requires_authority_and_converges_idempotently() {
    let fixture = Fixture::new();
    let app = fixture.app();
    let body = json!({"entryName": "proj1"});

    for control in [
        None,
        Some("entry-instance-migrate"),
        Some("ENTRY-INSTANCE-CREATE"),
    ] {
        let response = request(
            app.clone(),
            Method::POST,
            "/api/v2/entries",
            body.clone(),
            control,
        )
        .await;
        assert_eq!(response.status(), StatusCode::FORBIDDEN, "{control:?}");
    }

    let created = request(
        app.clone(),
        Method::POST,
        "/api/v2/entries",
        body.clone(),
        Some("entry-instance-create"),
    )
    .await;
    assert_eq!(created.status(), StatusCode::OK);
    let created = document(created).await;
    assert_eq!(
        created.as_object().unwrap().keys().collect::<Vec<_>>(),
        ["changed", "entry", "operation", "protocol"]
    );
    assert_eq!(created["protocol"], "swawkit.entry-instance-mutation/v1");
    assert_eq!(created["operation"], "create");
    assert_eq!(created["changed"], true);
    assert_eq!(created["entry"]["entryName"], "proj1");
    assert_eq!(created["entry"]["status"], "ready");

    let data_root = fixture.root.join("home/data/proj.proj1");
    assert!(fixture.root.join("home/proj1.exe").is_file());
    assert!(data_root.join("entry.id").is_file());
    assert!(data_root.join("launcher.json").is_file());
    assert!(data_root.join("runtime/current").is_file());

    let repeated = request(
        app,
        Method::POST,
        "/api/v2/entries",
        body,
        Some("entry-instance-create"),
    )
    .await;
    assert_eq!(repeated.status(), StatusCode::OK);
    assert_eq!(document(repeated).await["changed"], false);
}

#[tokio::test]
async fn migrate_requires_exact_legacy_evidence_and_control_header() {
    let fixture = Fixture::new();
    let data_root = fixture.directory("home/data/proj.legacy-one");
    fixture.file("home/legacy-one.exe", "legacy Launcher");
    fixture.file(
        "home/data/proj.legacy-one/_entry.json",
        &serde_json::to_string(&json!({
            "schema": "swawkit.proj-entry.v0",
            "entryName": "legacy-one",
            "entryFile": "legacy-one.exe",
            "volumeId": r"\\?\Volume{01234567-89ab-cdef-0123-456789abcdef}",
            "fileId": "0123456789abcdef",
        }))
        .unwrap(),
    );
    let app = fixture.app();
    let body = json!({"entryName": "legacy-one"});

    let forbidden = request(
        app.clone(),
        Method::POST,
        "/api/v2/entries/migrate",
        body.clone(),
        Some("entry-instance-create"),
    )
    .await;
    assert_eq!(forbidden.status(), StatusCode::FORBIDDEN);

    let migrated = request(
        app,
        Method::POST,
        "/api/v2/entries/migrate",
        body,
        Some("entry-instance-migrate"),
    )
    .await;
    assert_eq!(migrated.status(), StatusCode::OK);
    let migrated = document(migrated).await;
    assert_eq!(migrated["operation"], "migrate");
    assert_eq!(migrated["changed"], true);
    assert_eq!(migrated["entry"]["status"], "ready");
    assert!(data_root.join("entry.id").is_file());
    assert!(data_root.join("_entry.json").is_file());
}

#[tokio::test]
async fn maps_conflicts_and_io_without_exposing_routes_on_ordinary_entries() {
    let fixture = Fixture::new();
    fixture.file("home/conflict.exe", "foreign");
    let conflict = request(
        fixture.app(),
        Method::POST,
        "/api/v2/entries",
        json!({"entryName": "conflict"}),
        Some("entry-instance-create"),
    )
    .await;
    assert_eq!(conflict.status(), StatusCode::CONFLICT);

    let corrupt_fixture = Fixture::new();
    let corrupt_app = corrupt_fixture.app();
    fs::remove_file(
        corrupt_fixture
            .root
            .join("home/data/proj.swawkit/runtime/releases")
            .join(&corrupt_fixture.release_id)
            .join("swawkit-proj-dev.exe"),
    )
    .expect("corrupt manager Runtime");
    let corrupt = request(
        corrupt_app,
        Method::POST,
        "/api/v2/entries",
        json!({"entryName": "proj1"}),
        Some("entry-instance-create"),
    )
    .await;
    assert_eq!(corrupt.status(), StatusCode::CONFLICT);

    let io_fixture = Fixture::new();
    let io_app = io_fixture.app();
    fs::remove_file(io_fixture.root.join("home/swawkit.exe")).expect("remove manager Launcher");
    let io_failure = request(
        io_app,
        Method::POST,
        "/api/v2/entries",
        json!({"entryName": "proj1"}),
        Some("entry-instance-create"),
    )
    .await;
    assert_eq!(io_failure.status(), StatusCode::INTERNAL_SERVER_ERROR);

    let ordinary_fixture = Fixture::new();
    let ordinary = ordinary_app(&ordinary_fixture);
    for (method, path) in [
        (Method::GET, "/api/v2/entries"),
        (Method::POST, "/api/v2/entries/inspect"),
        (Method::POST, "/api/v2/entries"),
        (Method::POST, "/api/v2/entries/migrate"),
    ] {
        let response = request(
            ordinary.clone(),
            method,
            path,
            json!({"entryName": "another"}),
            Some("entry-instance-create"),
        )
        .await;
        assert_eq!(response.status(), StatusCode::NOT_FOUND, "{path}");
    }
}

fn ordinary_app(fixture: &Fixture) -> Router {
    let name = "ordinary";
    let home = fixture.root.join("home");
    let data_root = home.join("data/proj.ordinary");
    let runtime_root = data_root.join("runtime");
    fs::create_dir_all(runtime_root.join("releases")).expect("create ordinary Runtime root");
    let release_id = crate::runtime_release::tests::write_release(
        &home,
        &runtime_root.join("releases"),
        &[
            ("swawkit-proj.exe", b"core"),
            ("swawkit-proj-host.exe", b"host"),
            ("swawkit-proj-module.exe", b"module"),
            ("swawkit-proj-dev.exe", b"dev"),
        ],
    );
    fs::write(runtime_root.join("current"), format!("{release_id}\n"))
        .expect("write ordinary selector");
    let entry_file = home.join("ordinary.exe");
    fs::write(&entry_file, b"ordinary Launcher").expect("write ordinary Launcher");
    let entry_id = EntryId::create_once(&data_root).expect("create ordinary Entry ID");
    let context = EntryContext {
        swawkit_home: home.clone(),
        data_root: data_root.clone(),
        runtime_root,
        entry_file: entry_file.clone(),
        entry_name: name.to_owned(),
        entry_id,
        invocation_directory: fixture.root.clone(),
        product_executable: data_root
            .join("runtime/releases")
            .join(&release_id)
            .join("swawkit-proj-host.exe"),
        release_id,
    };
    let data_root = DataRootSession::new(ResolveDataRootRequest {
        swawkit_home: &home,
        entry_file: &entry_file,
    })
    .expect("open ordinary DataRoot");
    super::super::router(AUTHORITY.to_owned(), context, data_root)
}
