use axum::http::header::IF_MATCH;

use super::*;
use crate::{
    binding::SWAWKIT_HOME_PLACEHOLDER,
    entry_config::{ENTRY_CONFIG_DOCUMENT_PROTOCOL, ENTRY_CONFIG_SCHEMA},
};

async fn send_setting(
    app: Router,
    address: &str,
    value: Value,
    revision: Option<&str>,
) -> Response {
    let mut request = Request::builder()
        .method(Method::PUT)
        .uri(format!(
            "/api/v2/entry-config/settings/{}",
            address.replace('/', "%2F")
        ))
        .header(HOST, AUTHORITY)
        .header(CONTENT_TYPE, "application/json");
    if let Some(revision) = revision {
        request = request.header(IF_MATCH, format!("\"{revision}\""));
    }
    app.oneshot(
        request
            .body(Body::from(json!({ "value": value }).to_string()))
            .expect("valid JSON request"),
    )
    .await
    .expect("router response")
}

async fn response_document(response: Response) -> Value {
    let body = to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("JSON response body");
    serde_json::from_slice(&body).expect("response JSON")
}

#[tokio::test]
async fn missing_config_is_a_valid_default_without_a_project_namespace() {
    let fixture = Fixture::new();
    fixture.executable_resource("home/_lib/proj/system/demo", "run.ps1", "");
    fixture.executable_resource("home/.swaw/project-demo", "run.ps1", "");
    let app = fixture.app();

    let response = send(
        app.clone(),
        Method::GET,
        "/api/v2/entry-config",
        Some(AUTHORITY),
    )
    .await;
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response
            .headers()
            .get(ETAG)
            .and_then(|value| value.to_str().ok()),
        Some("\"missing\"")
    );
    let document = response_document(response).await;
    assert_eq!(document["protocol"], ENTRY_CONFIG_DOCUMENT_PROTOCOL);
    assert_eq!(document["revision"], "missing");
    assert_eq!(document["status"], "default");
    assert_eq!(document["config"]["schema"], ENTRY_CONFIG_SCHEMA);
    assert_eq!(document["config"]["language"], "zh-CN");
    assert_eq!(document["config"]["projectRoot"], Value::Null);
    assert_eq!(document["settings"].as_object().unwrap().len(), 2);
    assert_eq!(document["resolvedProjectRoot"], Value::Null);
    assert_eq!(document["error"], Value::Null);

    let catalog = catalog_document(app).await;
    assert!(command(&catalog, ".demo").is_some());
    assert!(command(&catalog, "project/project-demo").is_none());
}

#[tokio::test]
async fn semantic_invalid_config_exposes_a_valid_error_document() {
    let fixture = Fixture::new();
    fixture.file(
        "home/data/proj.swawkit/_entry-config.json",
        r#"{"schema":"swawkit.entry-config/v0","language":"invalid","projectRoot":null}"#,
    );
    fixture.executable_resource("home/_lib/proj/system/demo", "run.ps1", "");
    let app = fixture.app();

    let response = send(
        app.clone(),
        Method::GET,
        "/api/v2/entry-config",
        Some(AUTHORITY),
    )
    .await;
    assert_eq!(response.status(), StatusCode::OK);
    let document = response_document(response).await;
    assert_eq!(document["status"], "invalid");
    assert_eq!(document["config"]["schema"], ENTRY_CONFIG_SCHEMA);
    assert_eq!(document["config"]["language"], "zh-CN");
    assert!(document["error"].as_str().is_some());

    let catalog = catalog_document(app).await;
    assert_eq!(catalog["language"], "zh-CN");
    assert!(command(&catalog, ".demo").is_some());
}

#[tokio::test]
async fn validates_a_project_root_and_publishes_the_project_namespace() {
    let fixture = Fixture::new();
    fixture.executable_resource("home/.swaw/demo", "run.ps1", "");
    let app = fixture.app();
    let initial = response_document(
        send(
            app.clone(),
            Method::GET,
            "/api/v2/entry-config",
            Some(AUTHORITY),
        )
        .await,
    )
    .await;
    let revision = initial["revision"].as_str().unwrap();

    let invalid = send_setting(
        app.clone(),
        ".entry/project/root",
        json!("relative/project"),
        Some(revision),
    )
    .await;
    assert_eq!(invalid.status(), StatusCode::UNPROCESSABLE_ENTITY);
    assert!(
        response_document(invalid).await["error"]
            .as_str()
            .is_some_and(|error| error.contains("must be absolute"))
    );

    let saved = send_setting(
        app.clone(),
        ".entry/project/root",
        json!(SWAWKIT_HOME_PLACEHOLDER),
        Some(revision),
    )
    .await;
    assert_eq!(saved.status(), StatusCode::OK);
    let document = response_document(saved).await;
    assert_eq!(document["status"], "ready");
    assert_eq!(
        document["settings"][".entry/project/root"],
        SWAWKIT_HOME_PLACEHOLDER
    );
    assert_eq!(
        command(&catalog_document(app).await, "project/demo")
            .and_then(|node| node["namespace"].as_str()),
        Some("project")
    );
}

#[tokio::test]
async fn binding_unavailability_is_local_and_can_be_repaired() {
    let fixture = Fixture::new();
    fixture.file("home/_lib/proj/system/_help/zh-CN.txt", "Chinese help");
    fixture.file("home/_lib/proj/system/_help/en.txt", "English help");
    let unavailable_root = fixture.root.join("not-created-yet");
    let repaired_root = fixture.directory("repaired-project");
    fixture.executable_resource("repaired-project/.swaw/demo", "run.ps1", "");
    let app = fixture.app();
    let initial = response_document(
        send(
            app.clone(),
            Method::GET,
            "/api/v2/entry-config",
            Some(AUTHORITY),
        )
        .await,
    )
    .await;
    let language = response_document(
        send_setting(
            app.clone(),
            ".entry/language",
            json!("en"),
            initial["revision"].as_str(),
        )
        .await,
    )
    .await;
    let unavailable = send_setting(
        app.clone(),
        ".entry/project/root",
        json!(unavailable_root.to_string_lossy()),
        language["revision"].as_str(),
    )
    .await;
    assert_eq!(unavailable.status(), StatusCode::OK);
    let unavailable = response_document(unavailable).await;
    assert_eq!(unavailable["status"], "bindingUnavailable");
    assert_eq!(unavailable["config"]["language"], "en");
    assert!(unavailable["error"].as_str().is_some());
    let catalog = catalog_document(app.clone()).await;
    assert_eq!(catalog["language"], "en");
    assert!(command(&catalog, "project/demo").is_none());

    let repaired = send_setting(
        app.clone(),
        ".entry/project/root",
        json!(repaired_root.to_string_lossy()),
        unavailable["revision"].as_str(),
    )
    .await;
    assert_eq!(repaired.status(), StatusCode::OK);
    let repaired = response_document(repaired).await;
    assert_eq!(repaired["status"], "ready");
    assert_eq!(repaired["config"]["language"], "en");
    assert!(command(&catalog_document(app).await, "project/demo").is_some());
}

#[tokio::test]
async fn requires_a_revision_and_rejects_stale_or_stale_host_mutations() {
    let fixture = Fixture::new();
    let app = fixture.app();
    assert_eq!(
        send_setting(app.clone(), ".entry/language", json!("en"), None)
            .await
            .status(),
        StatusCode::PRECONDITION_REQUIRED
    );
    let initial = response_document(
        send(
            app.clone(),
            Method::GET,
            "/api/v2/entry-config",
            Some(AUTHORITY),
        )
        .await,
    )
    .await;
    let saved = response_document(
        send_setting(
            app.clone(),
            ".entry/language",
            json!("en"),
            initial["revision"].as_str(),
        )
        .await,
    )
    .await;
    fixture
        .config_store()
        .update_setting(".entry/language", Some("zh-CN".to_owned()))
        .expect("concurrent CLI update");
    let conflict = send_setting(
        app.clone(),
        ".entry/language",
        json!("en"),
        saved["revision"].as_str(),
    )
    .await;
    assert_eq!(conflict.status(), StatusCode::CONFLICT);
    assert!(
        response_document(conflict).await["error"]
            .as_str()
            .is_some_and(|error| error.contains("changed since it was loaded"))
    );

    let current = fixture.config_store().document();
    fixture.select_update();
    let stale_host =
        send_setting(app, ".entry/language", json!("en"), Some(&current.revision)).await;
    assert_eq!(stale_host.status(), StatusCode::CONFLICT);
    assert_eq!(
        response_document(stale_host).await["code"],
        crate::server::command_run::RUNTIME_UPDATE_REQUIRED_CODE
    );
    assert_eq!(fixture.config_store().document().config.language, "zh-CN");
}

#[tokio::test]
async fn project_root_can_be_cleared_without_erasing_language() {
    let fixture = Fixture::new();
    let app = fixture.app();
    let initial = fixture.config_store().document();
    let configured = response_document(
        send_setting(
            app.clone(),
            ".entry/language",
            json!("en"),
            Some(&initial.revision),
        )
        .await,
    )
    .await;
    let configured = response_document(
        send_setting(
            app.clone(),
            ".entry/project/root",
            json!(SWAWKIT_HOME_PLACEHOLDER),
            configured["revision"].as_str(),
        )
        .await,
    )
    .await;
    let cleared = send_setting(
        app,
        ".entry/project/root",
        Value::Null,
        configured["revision"].as_str(),
    )
    .await;
    assert_eq!(cleared.status(), StatusCode::OK);
    let cleared = response_document(cleared).await;
    assert_eq!(cleared["status"], "ready");
    assert_eq!(cleared["config"]["language"], "en");
    assert_eq!(cleared["config"]["projectRoot"], Value::Null);
}
