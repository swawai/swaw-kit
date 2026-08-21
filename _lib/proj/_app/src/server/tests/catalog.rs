use super::*;

#[tokio::test]
async fn rescans_the_catalog_on_each_request() {
    let fixture = Fixture::new();
    fixture.directory("home/_lib/proj");
    fixture
        .config_store()
        .save(crate::entry_config::EntryConfigRecord::default())
        .expect("ready Entry Config");
    let app = fixture.app();

    let before = catalog_document(app.clone()).await;
    assert!(command(&before, ".dynamic").is_none());

    fixture.executable_resource("home/_lib/proj/system/dynamic", "run.ps1", "");
    let after = catalog_document(app).await;
    assert_eq!(
        command(&after, ".dynamic").and_then(|node| node["runnable"].as_bool()),
        Some(true)
    );
}

#[tokio::test]
async fn returns_a_safe_error_when_catalog_discovery_fails() {
    let fixture = Fixture::new();
    fs::remove_dir_all(fixture.context().command_root()).expect("remove fixture command root");
    let response = send(
        fixture.app(),
        Method::GET,
        "/api/v2/catalog",
        Some(AUTHORITY),
    )
    .await;

    assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
    let body = to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("error body");
    let document: Value = serde_json::from_slice(&body).expect("error JSON");
    assert_eq!(document["error"], "catalog discovery failed");
}

#[tokio::test]
async fn serializes_the_resource_era_catalog_node_contract() {
    let fixture = Fixture::new();
    fixture.directory("home/_lib/proj");
    fixture.resource("home/_lib/proj/system/dev");
    fixture.subcommands("home/_lib/proj/system/dev");
    fixture.file(
        "home/_lib/proj/system/dev/subcommands/view/web.json",
        r#"{"schema":"swawkit.view-source/web/v1","column":{"width":"wide","body":{"component":"resource-list","source":"facet-result"}}}"#,
    );
    fixture.executable_resource(
        "home/_lib/proj/system/dev/subcommands/status",
        "run.cmd",
        "",
    );
    fixture.file(
        "home/_lib/proj/system/dev/subcommands/status/_help/zh-CN.txt",
        "Show {{ADDRESS}}\nUse {{INVOCATION}}",
    );

    let document = catalog_document(fixture.app()).await;
    assert_eq!(document["protocol"], "swawkit.command-catalog/v24");
    let group = command(&document, ".dev").expect("group node");
    assert_eq!(group["runnable"], false);
    assert!(group.get("module").is_none());
    assert_eq!(group["facets"][0]["id"], "subcommands");
    assert_eq!(group["facets"][0]["resolver"]["relation"], "subcommands");
    assert!(group["facets"][0].get("view").is_none());

    let status = command(&document, ".dev/status").expect("runnable node");
    assert_eq!(status["entry"], "run.cmd");
    assert_eq!(status["adapter"], "cmd");
    assert_eq!(status["help"]["summary"], "Show .dev/status");
    assert!(status.get("module").is_none());
    assert!(
        document["commands"]
            .as_array()
            .expect("commands array")
            .iter()
            .all(|node| node.get("directory").is_none())
    );
}
