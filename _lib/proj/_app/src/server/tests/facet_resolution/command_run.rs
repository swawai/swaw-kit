use super::*;

async fn start_run(app: Router, request: Value) -> Response {
    app.oneshot(
        Request::builder()
            .method(Method::POST)
            .uri("/api/v3/command-runs")
            .header(HOST, AUTHORITY)
            .header(CONTENT_TYPE, "application/json")
            .body(Body::from(
                serde_json::to_vec(&request).expect("command run request JSON"),
            ))
            .expect("command run request"),
    )
    .await
    .expect("command run response")
}

#[tokio::test]
async fn starts_a_dynamic_operation_only_through_its_route_local_grant() {
    let fixture = Fixture::new();
    context_surface(&fixture);
    fixture
        .config_store()
        .save(crate::entry_config::EntryConfigRecord::default())
        .expect("ready Entry Config");
    let mut documents = context_documents("release-check", json!([]), json!([]), false);
    documents.insert(
        vec![
            ".context/add".to_owned(),
            "release-check".to_owned(),
            ".dev/status".to_owned(),
        ],
        String::new(),
    );
    let response = start_run(
        facet_app(&fixture, documents),
        json!({
            "route": "$/system::context/contexts::release-check/add",
            "arguments": [".dev/status"]
        }),
    )
    .await;
    assert_eq!(response.status(), StatusCode::CREATED);
    let document: Value = serde_json::from_slice(
        &to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("dynamic operation body"),
    )
    .expect("dynamic operation JSON");
    assert_eq!(document["address"], ".context/add");

    let denied = resource_listing(
        "release-check",
        "no operation grant".to_owned(),
        json!(["overview"]),
    );
    let response = start_run(
        facet_app(
            &fixture,
            BTreeMap::from([(
                vec![".context/list".to_owned(), "--json".to_owned()],
                collection_document(json!([denied])),
            )]),
        ),
        json!({
            "route": "$/system::context/contexts::release-check/add",
            "arguments": [".dev/status"]
        }),
    )
    .await;
    assert_eq!(response.status(), StatusCode::NOT_FOUND);

    let response = start_run(
        facet_app(
            &fixture,
            context_documents("release-check", json!([]), json!([]), false),
        ),
        json!({
            "route": "$/system::context/contexts::release-check/delete",
            "arguments": ["browser-cannot-extend-fixed-argv"]
        }),
    )
    .await;
    assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
}
