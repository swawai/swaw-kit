use super::*;
use crate::binding::SWAWKIT_HOME_PLACEHOLDER;

async fn send_json(app: Router, value: Value) -> Response {
    app.oneshot(
        Request::builder()
            .method(Method::PUT)
            .uri("/api/v1/binding")
            .header(HOST, AUTHORITY)
            .header(CONTENT_TYPE, "application/json")
            .body(Body::from(value.to_string()))
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
async fn publishes_a_validated_target_and_enables_its_actions() {
    let fixture = Fixture::new();
    fixture.directory("home/_lib/proj");
    fixture.file("home/.swaw/demo/run.ps1", "");
    let app = fixture.app();

    let before = send(app.clone(), Method::GET, "/api/v1/binding", Some(AUTHORITY)).await;
    assert_eq!(before.status(), StatusCode::OK);
    assert_eq!(response_document(before).await["status"], "unbound");
    assert!(command(&catalog_document(app.clone()).await, "demo").is_none());

    let invalid = send_json(
        app.clone(),
        json!({ "targetProjectRoot": "relative/project" }),
    )
    .await;
    assert_eq!(invalid.status(), StatusCode::UNPROCESSABLE_ENTITY);
    assert!(
        response_document(invalid).await["error"]
            .as_str()
            .is_some_and(|error| error.contains("must be absolute"))
    );

    let saved = send_json(
        app.clone(),
        json!({ "targetProjectRoot": SWAWKIT_HOME_PLACEHOLDER }),
    )
    .await;
    assert_eq!(saved.status(), StatusCode::OK);
    let document = response_document(saved).await;
    assert_eq!(document["status"], "ready");
    assert_eq!(document["targetProjectRoot"], SWAWKIT_HOME_PLACEHOLDER);
    assert_eq!(
        command(&catalog_document(app).await, "demo")
            .and_then(|node| node["source"].as_str()),
        Some("action")
    );
}
