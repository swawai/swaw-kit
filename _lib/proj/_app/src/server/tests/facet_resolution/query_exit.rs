use super::*;

fn check_surface(fixture: &Fixture) {
    fixture.file(
        "home/_lib/proj/system/check/swawkit.module.json",
        include_str!("../../../../../system/check/swawkit.module.json"),
    );
    fixture.file(
        "home/_lib/proj/system/tool/swawkit.module.json",
        r#"{"schema":"swawkit.command-module/v11","requires":[{"provider":".provider","export":"fixture","contract":"fixture.report/v1"}]}"#,
    );
    fixture.file("home/_lib/proj/system/tool/run.cmd", "");
}

fn command_check_document(ready: bool) -> Value {
    let dependencies = if ready {
        json!([])
    } else {
        json!([{
            "provider": ".provider",
            "export": "fixture",
            "contract": "fixture.report/v1",
            "ready": false,
            "status": "provider-missing",
            "message": "provider command is absent from the Catalog",
            "dependencies": []
        }])
    };
    json!({
        "protocol": crate::command_check::COMMAND_CHECK_PROTOCOL,
        "command": {
            "address": ".tool",
            "space": "system",
            "namespace": null,
            "runnable": true,
            "adapter": "cmd",
            "diagnostic": null
        },
        "dependencies": dependencies,
        "ready": ready
    })
}

#[tokio::test]
async fn resolves_a_blocked_command_check_document_from_exit_code_one() {
    let fixture = Fixture::new();
    check_surface(&fixture);
    fixture
        .profile_store()
        .save(crate::profile::EntryProfileRecord::default())
        .expect("ready profile");
    let argv = vec![".check".to_owned(), ".tool".to_owned(), "--json".to_owned()];
    let document = command_check_document(false);
    let app = facet_app_with_exit_codes(
        &fixture,
        BTreeMap::from([(
            argv.clone(),
            serde_json::to_string(&document).expect("command-check JSON"),
        )]),
        BTreeMap::from([(argv, 1)]),
    );

    let response = resolve(
        app,
        json!({
            "subject": {"type":"command", "space":"system", "address":".tool"},
            "facet": "check"
        }),
    )
    .await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("command-check body");
    let resolved: Value = serde_json::from_slice(&body).expect("command-check response JSON");
    assert_eq!(resolved, document);
}

#[tokio::test]
async fn command_check_facet_does_not_mutate_entry_lifecycle_state() {
    let fixture = Fixture::new();
    let data_root = fixture.root.join("home/data/proj.swawkit");
    check_surface(&fixture);
    let argv = vec![".check".to_owned(), ".tool".to_owned(), "--json".to_owned()];
    let document = command_check_document(false);
    let app = facet_app_with_exit_codes(
        &fixture,
        BTreeMap::from([(
            argv.clone(),
            serde_json::to_string(&document).expect("command-check JSON"),
        )]),
        BTreeMap::from([(argv, 1)]),
    );

    let response = resolve(
        app,
        json!({
            "subject": {"type":"command", "space":"system", "address":".tool"},
            "facet": "check"
        }),
    )
    .await;

    assert_eq!(response.status(), StatusCode::OK);
    assert!(!data_root.join("_entry.json").exists());
    assert!(!data_root.join("launcher.json").exists());
}

#[tokio::test]
async fn rejects_exit_codes_that_violate_the_declared_return_protocol() {
    let fixture = Fixture::new();
    check_surface(&fixture);
    fixture.file(
        "home/_lib/proj/system/report/swawkit.module.json",
        r#"{"schema":"swawkit.command-module/v11","facets":[{"id":"status","kind":"projection","renderer":"overview","icon":"i","label":{"zh-CN":"状态","en":"Status"},"summary":{"zh-CN":"读取报告","en":"Read report"},"resolver":{"type":"command","address":".report/json","arguments":[],"returns":"fixture.report/v1"}}]}"#,
    );
    fixture.file(
        "home/_lib/proj/system/report/json/swawkit.module.json",
        r#"{"schema":"swawkit.command-module/v11"}"#,
    );
    fixture.file("home/_lib/proj/system/report/json/run.cmd", "");
    fixture
        .profile_store()
        .save(crate::profile::EntryProfileRecord::default())
        .expect("ready profile");
    let check_argv = vec![".check".to_owned(), ".tool".to_owned(), "--json".to_owned()];

    for (exit_code, ready) in [(0, false), (1, true), (2, false)] {
        let document = command_check_document(ready);
        let response = resolve(
            facet_app_with_exit_codes(
                &fixture,
                BTreeMap::from([(
                    check_argv.clone(),
                    serde_json::to_string(&document).expect("command-check JSON"),
                )]),
                BTreeMap::from([(check_argv.clone(), exit_code)]),
            ),
            json!({
                "subject": {"type":"command", "space":"system", "address":".tool"},
                "facet": "check"
            }),
        )
        .await;
        assert_eq!(
            response.status(),
            StatusCode::INTERNAL_SERVER_ERROR,
            "exit {exit_code}, ready {ready}"
        );
    }

    let report_argv = vec![".report/json".to_owned()];
    let response = resolve(
        facet_app_with_exit_codes(
            &fixture,
            BTreeMap::from([(
                report_argv.clone(),
                r#"{"protocol":"fixture.report/v1","value":42}"#.to_owned(),
            )]),
            BTreeMap::from([(report_argv, 1)]),
        ),
        json!({
            "subject": {"type":"command", "space":"system", "address":".report"},
            "facet": "status"
        }),
    )
    .await;
    assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
}
