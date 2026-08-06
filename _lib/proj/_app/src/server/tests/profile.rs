use super::*;
use crate::binding::SWAWKIT_HOME_PLACEHOLDER;

async fn send_variable(
    app: Router,
    name: &str,
    value: &str,
    revision: Option<&str>,
) -> Response {
    let mut request = Request::builder()
        .method(Method::PUT)
        .uri(format!("/api/v2/profile/variables/{name}"))
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
async fn publishes_one_validated_variable_and_enables_actions() {
    let fixture = Fixture::new();
    fixture.directory("home/_lib/proj");
    fixture.file("home/.swaw/demo/run.ps1", "");
    let app = fixture.app();

    let before = send(app.clone(), Method::GET, "/api/v2/profile", Some(AUTHORITY)).await;
    assert_eq!(before.status(), StatusCode::OK);
    assert_eq!(
        before
            .headers()
            .get(ETAG)
            .and_then(|value| value.to_str().ok()),
        Some("\"missing\"")
    );
    let document = response_document(before).await;
    assert_eq!(document["protocol"], "swawkit.entry-profile-state/v3");
    let initial_revision = document["revision"].as_str().expect("profile revision");
    assert_eq!(document["status"], "setupRequired");
    assert_eq!(document["requiredComplete"], false);
    assert_eq!(
        document["variables"]["SWAWKIT_PROJ_TARGET_PROJECT_ROOT"],
        SWAWKIT_HOME_PLACEHOLDER
    );
    assert_eq!(document["variables"].as_object().unwrap().len(), 32);
    assert!(command(&catalog_document(app.clone()).await, "demo").is_none());

    let invalid = send_variable(
        app.clone(),
        "SWAWKIT_PROJ_TARGET_PROJECT_ROOT",
        "relative/project",
        Some(initial_revision),
    )
    .await;
    assert_eq!(invalid.status(), StatusCode::UNPROCESSABLE_ENTITY);
    assert!(
        response_document(invalid).await["error"]
            .as_str()
            .is_some_and(|error| error.contains("must be absolute"))
    );

    let saved = send_variable(
        app.clone(),
        "SWAWKIT_PROJ_TARGET_PROJECT_ROOT",
        SWAWKIT_HOME_PLACEHOLDER,
        Some(initial_revision),
    )
    .await;
    assert_eq!(saved.status(), StatusCode::OK);
    let document = response_document(saved).await;
    assert_eq!(document["status"], "ready");
    assert_eq!(document["requiredComplete"], true);
    assert_eq!(
        document["variables"]["SWAWKIT_PROJ_TARGET_PROJECT_ROOT"],
        SWAWKIT_HOME_PLACEHOLDER
    );
    assert_eq!(
        command(&catalog_document(app).await, "demo").and_then(|node| node["source"].as_str()),
        Some("action")
    );
}

#[tokio::test]
async fn requires_a_revision_and_rejects_a_stale_variable_without_overwriting() {
    let fixture = Fixture::new();
    fixture.directory("home/_lib/proj");
    let app = fixture.app();

    let missing_precondition = send_variable(
        app.clone(),
        "SWAWKIT_PROJ_GIT_ID_NAME",
        "Web Writer",
        None,
    )
    .await;
    assert_eq!(
        missing_precondition.status(),
        StatusCode::PRECONDITION_REQUIRED
    );

    let initial = send(app.clone(), Method::GET, "/api/v2/profile", Some(AUTHORITY)).await;
    let initial = response_document(initial).await;
    let initial_revision = initial["revision"].as_str().unwrap();
    let saved = send_variable(
        app.clone(),
        "SWAWKIT_PROJ_GIT_ID_NAME",
        "Web Writer",
        Some(initial_revision),
    )
    .await;
    assert_eq!(saved.status(), StatusCode::OK);
    let saved = response_document(saved).await;
    let stale_revision = saved["revision"].as_str().unwrap();

    fixture
        .profile_store()
        .update_environment_variable("SWAWKIT_PROJ_GIT_ID_NAME", "CLI Writer".to_owned())
        .expect("concurrent CLI update");

    let conflict = send_variable(
        app,
        "SWAWKIT_PROJ_GIT_ID_EMAIL",
        "web@example.com",
        Some(stale_revision),
    )
    .await;
    assert_eq!(conflict.status(), StatusCode::CONFLICT);
    assert!(
        response_document(conflict).await["error"]
            .as_str()
            .is_some_and(|error| error.contains("changed since it was loaded"))
    );

    let document = fixture.profile_store().document();
    assert_eq!(document.profile.git.name, "CLI Writer");
    assert_eq!(document.profile.git.email, "");
}
