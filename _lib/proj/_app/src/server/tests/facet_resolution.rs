use std::collections::BTreeMap;
use std::io;
use std::sync::Arc;

use super::*;
use crate::entry_runner::{
    EntryOutputStream, EntryRunControl, EntryRunObserver, EntryRunOutcome, EntryRunSpec,
    EntryRunner,
};
use crate::server::command_run::CommandRuns;

mod query_exit;

fn context_surface(fixture: &Fixture) {
    fixture.file(
        "home/_lib/proj/modules/context/swawkit.module.json",
        include_str!("../../../../modules/context/swawkit.module.json"),
    );
    for name in [
        "add", "delete", "list", "new", "note", "prompt", "remove", "render", "show",
    ] {
        fixture.file(
            &format!("home/_lib/proj/modules/context/{name}/swawkit.module.json"),
            r#"{"schema":"swawkit.command-module/v9","execution":{"type":"delegate","owner":{"type":"command","space":"module","namespace":"swaw","address":"swaw/context"}}}"#,
        );
    }
}

fn runs_surface(fixture: &Fixture) {
    fixture.file(
        "home/_lib/proj/system/runs/swawkit.module.json",
        include_str!("../../../../system/runs/swawkit.module.json"),
    );
}

async fn resolve(app: Router, request: Value) -> Response {
    app.oneshot(
        Request::builder()
            .method(Method::POST)
            .uri("/api/v2/facet-resolutions")
            .header(HOST, AUTHORITY)
            .header(CONTENT_TYPE, "application/json")
            .body(Body::from(
                serde_json::to_vec(&request).expect("request JSON"),
            ))
            .expect("facet resolution request"),
    )
    .await
    .expect("facet resolution response")
}

struct FacetQueryRunner {
    documents: BTreeMap<Vec<String>, String>,
    exit_codes: BTreeMap<Vec<String>, i32>,
}

impl EntryRunner for FacetQueryRunner {
    fn start(
        &self,
        spec: EntryRunSpec,
        observer: Arc<dyn EntryRunObserver>,
    ) -> io::Result<Arc<dyn EntryRunControl>> {
        let argv = spec
            .argv
            .iter()
            .map(|value| value.to_string_lossy().into_owned())
            .collect::<Vec<_>>();
        let document = self.documents.get(&argv).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                format!("no fake facet document for {argv:?}"),
            )
        })?;
        let exit_code = self.exit_codes.get(&argv).copied().unwrap_or(0);
        observer.output(EntryOutputStream::Stdout, document.clone());
        observer.completed(EntryRunOutcome::Exited(exit_code));
        Ok(Arc::new(CompletedQuery))
    }
}

struct CompletedQuery;

impl EntryRunControl for CompletedQuery {
    fn cancel(&self) -> io::Result<()> {
        Ok(())
    }

    fn join(&self) -> Result<(), String> {
        Ok(())
    }
}

fn facet_app(fixture: &Fixture, documents: BTreeMap<Vec<String>, String>) -> Router {
    facet_app_with_exit_codes(fixture, documents, BTreeMap::new())
}

fn facet_app_with_exit_codes(
    fixture: &Fixture,
    documents: BTreeMap<Vec<String>, String>,
    exit_codes: BTreeMap<Vec<String>, i32>,
) -> Router {
    let runner: Arc<dyn EntryRunner> = Arc::new(FacetQueryRunner {
        documents,
        exit_codes,
    });
    router_with_runs(
        AUTHORITY.to_owned(),
        fixture.context(),
        fixture.data_root_session(),
        CommandRuns::new(runner),
        test_host_runtime(),
        HostControl::new(),
    )
}

fn context_documents(
    id: &str,
    commands: Value,
    notes: Value,
    include_record: bool,
) -> BTreeMap<Vec<String>, String> {
    let command_count = commands.as_array().map_or(0, Vec::len);
    let note_count = notes.as_array().map_or(0, Vec::len);
    let collection = json!({
        "protocol": "swawkit.subject-collection/v3",
        "owner": command_ref(),
        "facet": "contexts",
        "subjects": [{
            "ref": context_ref(id),
            "label": format!("::context/{id}"),
            "summary": format!("{command_count} 个命令 · {note_count} 条说明"),
            "facetIds": ["overview", "render", "add", "remove", "note", "prompt", "delete"]
        }]
    });
    let mut documents = BTreeMap::from([(
        vec!["swaw/context/list".to_owned(), "--json".to_owned()],
        serde_json::to_string(&collection).expect("Context collection JSON"),
    )]);
    if include_record {
        let record = json!({
            "schema": "swawkit.context/v2",
            "id": id,
            "commands": commands,
            "notes": notes,
            "prompt": ""
        });
        documents.insert(
            vec!["swaw/context/show".to_owned(), id.to_owned()],
            serde_json::to_string(&record).expect("Context record JSON"),
        );
    }
    documents
}

fn command_ref() -> Value {
    json!({"type": "command", "space": "module", "namespace": "swaw", "address": "swaw/context"})
}

fn context_ref(id: &str) -> Value {
    json!({"type": "instance", "kind": "context", "id": id})
}

fn collection_document(subjects: Value) -> String {
    serde_json::to_string(&json!({
        "protocol": "swawkit.subject-collection/v3",
        "owner": command_ref(),
        "facet": "contexts",
        "subjects": subjects,
    }))
    .expect("collection document")
}

#[tokio::test]
async fn resolves_a_declared_collection_and_projects_subject_facets() {
    let fixture = Fixture::new();
    context_surface(&fixture);
    fixture
        .profile_store()
        .save(crate::profile::EntryProfileRecord::default())
        .expect("ready profile");
    let documents = context_documents(
        "mycontext01",
        json!([{"space": "system", "address": ".dev/status"}]),
        json!(["Inspect the environment"]),
        false,
    );

    let response = resolve(
        facet_app(&fixture, documents),
        json!({"subject": command_ref(), "facet": "contexts"}),
    )
    .await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("Context collection body");
    let document: Value = serde_json::from_slice(&body).expect("Context collection JSON");
    assert_eq!(document["protocol"], "swawkit.subject-collection/v3");
    assert_eq!(document["owner"], command_ref());
    assert_eq!(document["facet"], "contexts");
    assert_eq!(document["subjects"][0]["ref"], context_ref("mycontext01"));
    assert_eq!(document["subjects"][0]["summary"], "1 个命令 · 1 条说明");
    let facet_ids = document["subjects"][0]["facetIds"]
        .as_array()
        .expect("facet ids");
    assert!(facet_ids.contains(&json!("overview")));
    assert!(facet_ids.contains(&json!("add")));
    assert!(document["subjects"][0].get("facets").is_none());
}

#[tokio::test]
async fn resolves_an_instance_projection_only_through_its_declared_via_collection() {
    let fixture = Fixture::new();
    context_surface(&fixture);
    fixture
        .profile_store()
        .save(crate::profile::EntryProfileRecord::default())
        .expect("ready profile");
    let documents = context_documents("release-check", json!([]), json!([]), true);
    let app = facet_app(&fixture, documents);

    let response = resolve(
        app.clone(),
        json!({
            "subject": context_ref("release-check"),
            "facet": "overview",
            "via": {"subject": command_ref(), "facet": "contexts"}
        }),
    )
    .await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("Context body");
    let document: Value = serde_json::from_slice(&body).expect("Context JSON");
    assert_eq!(document["schema"], "swawkit.context/v2");
    assert_eq!(document["id"], "release-check");

    assert_eq!(
        resolve(
            app.clone(),
            json!({"subject": context_ref("release-check"), "facet": "overview"}),
        )
        .await
        .status(),
        StatusCode::UNPROCESSABLE_ENTITY
    );
    assert_eq!(
        resolve(
            app,
            json!({
                "subject": context_ref("missing"),
                "facet": "overview",
                "via": {"subject": command_ref(), "facet": "contexts"}
            }),
        )
        .await
        .status(),
        StatusCode::NOT_FOUND
    );
}

#[tokio::test]
async fn resolves_a_command_runs_collection_through_the_runs_subject_kind_provider() {
    let fixture = Fixture::new();
    runs_surface(&fixture);
    fixture.file(
        "home/_lib/proj/system/tool/swawkit.module.json",
        r#"{"schema":"swawkit.command-module/v9"}"#,
    );
    fixture.file("home/_lib/proj/system/tool/run.cmd", "");
    fixture
        .profile_store()
        .save(crate::profile::EntryProfileRecord::default())
        .expect("ready profile");
    let tool_ref = json!({"type": "command", "space": "system", "address": ".tool"});
    let run_ref = json!({"type": "instance", "kind": "run", "id": "run-01"});
    let collection = json!({
        "protocol": "swawkit.subject-collection/v3",
        "owner": tool_ref,
        "facet": "runs",
        "subjects": [{
            "ref": run_ref,
            "label": "2026-08-16 00:00:00.000Z",
            "summary": ".tool · exited · CLI · 1 events",
            "facetIds": ["overview", "open"]
        }]
    });
    let journal = json!({
        "schema": "swawkit.command-run-journal/v2",
        "id": "run-01"
    });
    let app = facet_app(
        &fixture,
        BTreeMap::from([
            (
                vec![".runs".to_owned(), "--json".to_owned(), ".tool".to_owned()],
                serde_json::to_string(&collection).expect("Run collection JSON"),
            ),
            (
                vec![".runs".to_owned(), "--run".to_owned(), "run-01".to_owned()],
                serde_json::to_string(&journal).expect("Run journal JSON"),
            ),
        ]),
    );

    let response = resolve(app.clone(), json!({"subject": tool_ref, "facet": "runs"})).await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("Run collection body");
    let document: Value = serde_json::from_slice(&body).expect("Run collection JSON");
    assert_eq!(document["owner"]["address"], ".tool");
    assert_eq!(document["subjects"][0]["ref"], run_ref);

    let response = resolve(
        app,
        json!({
            "subject": run_ref,
            "facet": "overview",
            "via": {"subject": tool_ref, "facet": "runs"}
        }),
    )
    .await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("Run journal body");
    let document: Value = serde_json::from_slice(&body).expect("Run journal JSON");
    assert_eq!(document["schema"], "swawkit.command-run-journal/v2");
    assert_eq!(document["id"], "run-01");
}

#[tokio::test]
async fn resolves_the_runs_commands_all_collection_as_a_distinct_global_scope() {
    let fixture = Fixture::new();
    runs_surface(&fixture);
    fixture
        .profile_store()
        .save(crate::profile::EntryProfileRecord::default())
        .expect("ready profile");
    let owner = json!({"type": "command", "space": "system", "address": ".runs"});
    let run_ref = json!({"type": "instance", "kind": "run", "id": "run-01"});
    let collection = json!({
        "protocol": "swawkit.subject-collection/v3",
        "owner": owner,
        "facet": "all",
        "subjects": [{
            "ref": run_ref,
            "label": "2026-08-16 00:00:00.000Z",
            "summary": ".tool · exited · CLI · 1 events",
            "facetIds": ["overview", "open"]
        }]
    });
    let app = facet_app(
        &fixture,
        BTreeMap::from([(
            vec![".runs".to_owned(), "--json".to_owned()],
            serde_json::to_string(&collection).expect("global Run collection JSON"),
        )]),
    );

    let response = resolve(app, json!({"subject": owner, "facet": "all"})).await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("global Run collection body");
    let document: Value = serde_json::from_slice(&body).expect("global Run collection JSON");
    assert_eq!(document["owner"]["address"], ".runs");
    assert_eq!(document["facet"], "all");
    assert_eq!(document["subjects"][0]["ref"], run_ref);
}

#[tokio::test]
async fn rejects_unknown_facets_and_the_removed_context_specific_routes() {
    let fixture = Fixture::new();
    context_surface(&fixture);
    fixture
        .profile_store()
        .save(crate::profile::EntryProfileRecord::default())
        .expect("ready profile");
    let app = facet_app(&fixture, BTreeMap::new());

    assert_eq!(
        resolve(
            app.clone(),
            json!({"subject": command_ref(), "facet": "missing"}),
        )
        .await
        .status(),
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        resolve(
            app.clone(),
            json!({"subject": command_ref(), "facet": "Overview"}),
        )
        .await
        .status(),
        StatusCode::UNPROCESSABLE_ENTITY
    );
    assert_eq!(
        resolve(
            app.clone(),
            json!({
                "subject": context_ref("test"),
                "facet": "overview",
                "via": {
                    "subject": command_ref(),
                    "facet": "contexts",
                    "resolver": {"type": "command", "address": "swaw/context/list"},
                    "arguments": ["--json"]
                }
            }),
        )
        .await
        .status(),
        StatusCode::UNPROCESSABLE_ENTITY
    );
    for path in [
        "/api/v2/subject-collections/.context/contexts",
        "/api/v2/contexts/missing",
    ] {
        assert_eq!(
            send(app.clone(), Method::GET, path, Some(AUTHORITY))
                .await
                .status(),
            StatusCode::NOT_FOUND,
            "{path}"
        );
    }
}

#[tokio::test]
async fn executes_any_declared_query_command_without_a_domain_handler() {
    let fixture = Fixture::new();
    fixture.file(
        "home/_lib/proj/system/report/swawkit.module.json",
        r#"{"schema":"swawkit.command-module/v9","facets":[{"id":"status","kind":"projection","renderer":"overview","icon":"i","label":{"zh-CN":"状态","en":"Status"},"summary":{"zh-CN":"读取报告","en":"Read report"},"resolver":{"type":"command","address":".report/json","arguments":[],"returns":"fixture.report/v1"}}]}"#,
    );
    fixture.file(
        "home/_lib/proj/system/report/json/swawkit.module.json",
        r#"{"schema":"swawkit.command-module/v9"}"#,
    );
    fixture.file("home/_lib/proj/system/report/json/run.cmd", "");
    fixture
        .profile_store()
        .save(crate::profile::EntryProfileRecord::default())
        .expect("ready profile");
    let app = facet_app(
        &fixture,
        BTreeMap::from([(
            vec![".report/json".to_owned()],
            r#"{"protocol":"fixture.report/v1","value":42}"#.to_owned(),
        )]),
    );

    let response = resolve(
        app,
        json!({
            "subject": {"type":"command", "space":"system", "address":".report"},
            "facet": "status"
        }),
    )
    .await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("report body");
    let document: Value = serde_json::from_slice(&body).expect("report JSON");
    assert_eq!(
        document,
        json!({"protocol":"fixture.report/v1", "value":42})
    );
}

#[tokio::test]
async fn validates_resolved_collections_before_using_their_subject_facets() {
    let fixture = Fixture::new();
    context_surface(&fixture);
    fixture
        .profile_store()
        .save(crate::profile::EntryProfileRecord::default())
        .expect("ready profile");
    let summary = json!({
        "ref": context_ref("release-check"),
        "label": "::context/release-check",
        "summary": "1 command",
        "facetIds": ["overview"],
    });
    let duplicate_app = facet_app(
        &fixture,
        BTreeMap::from([(
            vec!["swaw/context/list".to_owned(), "--json".to_owned()],
            collection_document(json!([summary.clone(), summary])),
        )]),
    );
    assert_eq!(
        resolve(
            duplicate_app,
            json!({
                "subject": context_ref("release-check"),
                "facet": "overview",
                "via": {"subject": command_ref(), "facet": "contexts"}
            }),
        )
        .await
        .status(),
        StatusCode::INTERNAL_SERVER_ERROR
    );

    let invalid_shape_app = facet_app(
        &fixture,
        BTreeMap::from([(
            vec!["swaw/context/list".to_owned(), "--json".to_owned()],
            collection_document(json!([{
                "ref": context_ref("release-check"),
                "label": "::context/release-check",
                "summary": "1 command",
                "facetIds": []
            }])),
        )]),
    );
    assert_eq!(
        resolve(
            invalid_shape_app,
            json!({"subject": command_ref(), "facet": "contexts"}),
        )
        .await
        .status(),
        StatusCode::INTERNAL_SERVER_ERROR
    );

    let invalid_target_app = facet_app(
        &fixture,
        BTreeMap::from([(
            vec!["swaw/context/list".to_owned(), "--json".to_owned()],
            collection_document(json!([{
                "ref": context_ref("release-check"),
                "label": "::context/release-check",
                "summary": "1 command",
                "facetIds": ["missing"]
            }])),
        )]),
    );
    assert_eq!(
        resolve(
            invalid_target_app,
            json!({"subject": command_ref(), "facet": "contexts"}),
        )
        .await
        .status(),
        StatusCode::INTERNAL_SERVER_ERROR
    );
}
