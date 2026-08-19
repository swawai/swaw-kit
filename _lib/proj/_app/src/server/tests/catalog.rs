use super::*;

#[tokio::test]
async fn rescans_the_catalog_on_each_request() {
    let fixture = Fixture::new();
    fixture.directory("home/_lib/proj");
    fixture
        .profile_store()
        .save(crate::profile::EntryProfileRecord::default())
        .expect("ready profile");
    let app = fixture.app();

    let before = catalog_document(app.clone()).await;
    assert!(command(&before, ".dynamic").is_none());

    fixture.file(
        "home/_lib/proj/system/dynamic/swawkit.module.json",
        r#"{"schema":"swawkit.command-module/v11"}"#,
    );
    fixture.file("home/_lib/proj/system/dynamic/run.ps1", "");
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
async fn serializes_the_complete_catalog_node_contract() {
    let fixture = Fixture::new();
    fixture.directory("home/_lib/proj");
    fixture.file(
        "home/_lib/proj/system/dev/swawkit.module.json",
        r#"{"schema":"swawkit.command-module/v11"}"#,
    );
    fixture.file("home/_lib/proj/system/dev/status/run.cmd", "");
    fixture.file(
        "home/_lib/proj/system/dev/status/swawkit.module.json",
        r#"{"schema":"swawkit.command-module/v11","requires":[{"provider":".dev/setup","export":"environment","contract":"swawkit.dev/v1"}],"provides":[{"id":"status","contract":"swawkit.status/v1"}]}"#,
    );
    fixture.file(
        "home/_lib/proj/system/dev/_view/web.json",
        r#"{"schema":"swawkit.command-view/web/v4","childrenColumn":{"width":"wide"}}"#,
    );
    fixture.file(
        "home/_lib/proj/system/dev/status/_view/web.json",
        r#"{"schema":"swawkit.command-view/web/v4","run":{"operations":[{"id":"preview","label":"Preview","arguments":[]},{"id":"apply","label":"Apply","arguments":["--apply"],"confirmation":"Confirm cleanup."}]}}"#,
    );
    fixture.file(
        "home/_lib/proj/system/dev/status/_help/zh-CN.txt",
        "Show {{ADDRESS}}\nUse {{INVOCATION}}",
    );
    fixture.file(
        "home/_lib/proj/system/help/swawkit.module.json",
        r#"{"schema":"swawkit.command-module/v11"}"#,
    );
    fixture.file("home/_lib/proj/system/help/run.ps1", "");
    fixture.file(
        "home/_lib/proj/system/broken/swawkit.module.json",
        r#"{"schema":"swawkit.command-module/v11"}"#,
    );
    fixture.file("home/_lib/proj/system/broken/run.ps1", "");
    fixture.file("home/_lib/proj/system/broken/run.cmd", "");

    let document = catalog_document(fixture.app()).await;
    assert_eq!(
        command(&document, ".dev").expect("group node"),
        &json!({
            "address": ".dev",
            "space": "system",
            "namespace": null,
            "path": ["dev"],
            "parent": "",
            "aliasOf": null,
            "runnable": false,
            "entry": null,
            "adapter": null,
            "handler": null,
            "product": null,
            "module": {
                "schema": "swawkit.command-module/v11",
                "requires": [],
                "provides": []
            },
            "help": null,
            "subjectKinds": [],
            "facets": [
                {
                    "id": "children",
                    "kind": "collection",
                    "renderer": "collection",
                    "icon": "□",
                    "label": "子命令",
                    "summary": "浏览静态子命令",
                    "resolver": {
                        "type": "catalog",
                        "relation": "children"
                    }
                },
                {
                    "id": "help",
                    "kind": "operation",
                    "renderer": "help",
                    "icon": "?",
                    "label": "帮助",
                    "summary": "阅读命令说明",
                    "resolver": {
                        "type": "command",
                        "address": ".help",
                        "arguments": [".dev"]
                    }
                }
            ],
            "view": {
                "childrenColumn": {
                    "width": "wide"
                }
            },
            "diagnostic": null
        })
    );
    assert_eq!(
        command(&document, ".dev/status").expect("runnable node"),
        &json!({
            "address": ".dev/status",
            "space": "system",
            "namespace": null,
            "path": ["dev", "status"],
            "parent": ".dev",
            "aliasOf": null,
            "runnable": true,
            "entry": "run.cmd",
            "adapter": "cmd",
            "handler": null,
            "product": null,
            "module": {
                "schema": "swawkit.command-module/v11",
                "requires": [{
                    "provider": ".dev/setup",
                    "export": "environment",
                    "contract": "swawkit.dev/v1"
                }],
                "provides": [{
                    "id": "status",
                    "contract": "swawkit.status/v1"
                }]
            },
            "help": {
                "summary": "Show .dev/status",
                "text": "Show .dev/status\nUse swawkit .dev/status"
            },
            "subjectKinds": [],
            "facets": [
                {
                    "id": "help",
                    "kind": "operation",
                    "renderer": "help",
                    "icon": "?",
                    "label": "帮助",
                    "summary": "阅读命令说明",
                    "resolver": {
                        "type": "command",
                        "address": ".help",
                        "arguments": [".dev/status"]
                    }
                },
                {
                    "id": "run",
                    "kind": "operation",
                    "renderer": "run",
                    "icon": ">",
                    "label": "执行",
                    "summary": "设置参数并启动命令",
                    "resolver": {
                        "type": "command",
                        "address": ".dev/status",
                        "arguments": [],
                        "acceptsTail": true
                    }
                }
            ],
            "view": {
                "run": {
                    "operations": [
                        {
                            "id": "preview",
                            "label": "Preview",
                            "arguments": []
                        },
                        {
                            "id": "apply",
                            "label": "Apply",
                            "arguments": ["--apply"],
                            "confirmation": "Confirm cleanup."
                        }
                    ]
                }
            },
            "diagnostic": null
        })
    );
    assert!(command(&document, ".h").is_none());
    assert!(
        command(&document, ".broken")
            .and_then(|node| node["diagnostic"].as_str())
            .is_some_and(|message| message.contains("multiple run entries"))
    );
    assert!(
        document["commands"]
            .as_array()
            .expect("commands array")
            .iter()
            .all(|node| node.get("directory").is_none())
    );
}
