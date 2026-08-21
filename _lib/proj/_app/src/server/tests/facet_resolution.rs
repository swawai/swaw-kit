use std::collections::BTreeMap;
use std::io;
use std::path::Path;
use std::sync::Arc;

use super::*;
use crate::process_runner::{ProcessControl, ProcessObserver, ProcessOutcome, ProcessOutputStream};
use crate::runtime_service::{PreparedExecution, RuntimeExecutionRunner, RuntimeService};

mod command_run;
mod query_exit;

fn context_surface(fixture: &Fixture) {
    let source = Path::new(env!("CARGO_MANIFEST_DIR")).join("../system/context");
    let target = fixture.directory("home/_lib/proj/system/context");
    fs::copy(
        source.join("swawkit.resource.json"),
        target.join("swawkit.resource.json"),
    )
    .expect("copy Context Resource marker");
    for name in ["execute", "subcommands", "contexts"] {
        copy_authoring_tree(&source.join(name), &target.join(name));
    }
}

fn copy_authoring_tree(source: &Path, target: &Path) {
    fs::create_dir_all(target).expect("create Resource authoring fixture directory");
    for entry in fs::read_dir(source).expect("read Resource authoring fixture") {
        let entry = entry.expect("read Resource authoring fixture entry");
        let target = target.join(entry.file_name());
        if entry.file_type().expect("read fixture entry type").is_dir() {
            copy_authoring_tree(&entry.path(), &target);
        } else {
            fs::copy(entry.path(), target).expect("copy Resource authoring fixture file");
        }
    }
}

fn runs_surface(fixture: &Fixture) {
    let source = Path::new(env!("CARGO_MANIFEST_DIR")).join("../system/runs");
    let target = fixture.directory("home/_lib/proj/system/runs");
    fs::copy(
        source.join("swawkit.resource.json"),
        target.join("swawkit.resource.json"),
    )
    .expect("copy Runs Resource marker");
    for name in ["execute", "all"] {
        copy_authoring_tree(&source.join(name), &target.join(name));
    }
}

fn runs_reference(fixture: &Fixture, resource: &str) {
    fixture.file(
        &format!("{resource}/runs/swawkit.facet.json"),
        r#"{"schema":"swawkit.facet/v1","kind":"collection","presentation":{"icon":"=","label":{"zh-CN":"运行记录","en":"Runs"},"summary":{"zh-CN":"浏览该命令的持久运行","en":"Browse persisted runs for this command"}}}"#,
    );
    fixture.file(
        &format!("{resource}/runs/swawkit.resource-kind.json"),
        r#"{"schema":"swawkit.resource-kind/v1","ref":"$/system::runs/all"}"#,
    );
    fixture.file(
        &format!("{resource}/runs/swawkit.execution.json"),
        r#"{"schema":"swawkit.facet-execution/v2","implementation":{"type":"invoke","target":"$/system::runs/execute","arguments":["--json",{"bind":"resource.route"}],"returns":"swawkit.resource-list/v2"}}"#,
    );
}

fn report_surface(fixture: &Fixture) {
    fixture.resource("home/_lib/proj/system/report");
    fixture.subcommands("home/_lib/proj/system/report");
    fixture.executable_resource(
        "home/_lib/proj/system/report/subcommands/json",
        "run.cmd",
        "",
    );
    fixture.file(
        "home/_lib/proj/system/report/status/swawkit.facet.json",
        r#"{"schema":"swawkit.facet/v1","kind":"projection","presentation":{"icon":"i","label":{"zh-CN":"状态","en":"Status"},"summary":{"zh-CN":"读取报告","en":"Read report"}}}"#,
    );
    fixture.file(
        "home/_lib/proj/system/report/status/swawkit.execution.json",
        r#"{"schema":"swawkit.facet-execution/v2","implementation":{"type":"invoke","target":"$/system::report/subcommands::json/execute","arguments":[],"returns":"fixture.report/v1"}}"#,
    );
}

async fn resolve(app: Router, request: Value) -> Response {
    app.oneshot(
        Request::builder()
            .method(Method::POST)
            .uri("/api/v3/facet-resolutions")
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

async fn resolve_view(app: Router, request: Value) -> Response {
    app.oneshot(
        Request::builder()
            .method(Method::POST)
            .uri("/api/v3/view-bundles")
            .header(HOST, AUTHORITY)
            .header(CONTENT_TYPE, "application/json")
            .body(Body::from(
                serde_json::to_vec(&request).expect("request JSON"),
            ))
            .expect("view bundle request"),
    )
    .await
    .expect("view bundle response")
}

struct FacetQueryRunner {
    documents: BTreeMap<Vec<String>, String>,
    exit_codes: BTreeMap<Vec<String>, i32>,
}

impl RuntimeExecutionRunner for FacetQueryRunner {
    fn start(
        &self,
        execution: PreparedExecution,
        observer: Arc<dyn ProcessObserver>,
    ) -> io::Result<Arc<dyn ProcessControl>> {
        let argv = execution
            .argv()
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
        observer.output(ProcessOutputStream::Stdout, document.clone());
        observer.completed(ProcessOutcome::Exited(exit_code));
        Ok(Arc::new(CompletedQuery))
    }
}

struct CompletedQuery;

impl ProcessControl for CompletedQuery {
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
    let runner: Arc<dyn RuntimeExecutionRunner> = Arc::new(FacetQueryRunner {
        documents,
        exit_codes,
    });
    let context = fixture.context();
    let data_root = fixture.data_root_session();
    let runtime_service = RuntimeService::new(context.clone(), data_root.clone(), runner);
    let host_runtime = test_host_runtime(&context);
    router_with_runtime_service(
        AUTHORITY.to_owned(),
        context,
        data_root,
        runtime_service,
        host_runtime,
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
    let collection = collection_document(json!([resource_listing(
        id,
        format!("{command_count} 个命令 · {note_count} 条说明"),
        json!([
            "overview", "render", "add", "remove", "note", "prompt", "delete"
        ]),
    )]));
    let mut documents = BTreeMap::from([(
        vec![".context/list".to_owned(), "--json".to_owned()],
        collection,
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
            vec![".context/show".to_owned(), id.to_owned()],
            serde_json::to_string(&record).expect("Context record JSON"),
        );
    }
    documents
}

fn context_kind_route() -> Value {
    json!({
        "resource": {"hops": [{"facet": "system", "selector": "context"}]},
        "facet": "contexts"
    })
}

fn resource_listing(id: &str, summary: String, facet_ids: Value) -> Value {
    json!({
        "identity": {"type": "instance", "kind": context_kind_route(), "id": id},
        "selector": id,
        "route": {"hops": [
            {"facet": "system", "selector": "context"},
            {"facet": "contexts", "selector": id}
        ]},
        "facetIds": facet_ids,
        "label": id,
        "summary": summary
    })
}

fn collection_document(resources: Value) -> String {
    serde_json::to_string(&json!({
        "protocol": "swawkit.resource-list/v2",
        "source": context_kind_route(),
        "resources": resources,
    }))
    .expect("Resource List document")
}

#[tokio::test]
async fn resolves_a_declared_collection_with_route_scoped_resource_grants() {
    let fixture = Fixture::new();
    context_surface(&fixture);
    fixture
        .config_store()
        .save(crate::entry_config::EntryConfigRecord::default())
        .expect("ready Entry Config");
    let documents = context_documents(
        "mycontext01",
        json!([{"space": "system", "address": ".dev/status"}]),
        json!(["Inspect the environment"]),
        false,
    );

    let app = facet_app(&fixture, documents);
    let response = resolve(app.clone(), json!({"route": "$/system::context/contexts"})).await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("Context collection body");
    let document: Value = serde_json::from_slice(&body).expect("Context collection JSON");
    assert_eq!(document["protocol"], "swawkit.resource-list/v2");
    assert_eq!(document["source"], context_kind_route());
    assert_eq!(
        document["resources"][0]["identity"],
        json!({"type": "instance", "kind": context_kind_route(), "id": "mycontext01"})
    );
    assert_eq!(document["resources"][0]["summary"], "1 个命令 · 1 条说明");
    let facet_ids = document["resources"][0]["facetIds"]
        .as_array()
        .expect("facet ids");
    assert!(facet_ids.contains(&json!("overview")));
    assert!(facet_ids.contains(&json!("add")));
    assert!(document["resources"][0].get("facets").is_none());

    let response = resolve_view(app, json!({"route": "$/system::context/contexts"})).await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("Context View Bundle body");
    let bundle: Value = serde_json::from_slice(&body).expect("Context View Bundle JSON");
    assert_eq!(bundle["protocol"], "swawkit.view-bundle/web/v1");
    assert_eq!(bundle["target"], context_kind_route());
    assert_eq!(bundle["view"]["width"], "wide");
    assert_eq!(
        bundle["resources"]["facet-result"]["protocol"],
        "swawkit.resource-list/v2"
    );
}

#[tokio::test]
async fn resolves_an_instance_projection_only_through_its_collection_route() {
    let fixture = Fixture::new();
    context_surface(&fixture);
    fixture
        .config_store()
        .save(crate::entry_config::EntryConfigRecord::default())
        .expect("ready Entry Config");
    let documents = context_documents("release-check", json!([]), json!([]), true);
    let app = facet_app(&fixture, documents);

    let response = resolve(
        app.clone(),
        json!({"route": "$/system::context/contexts::release-check/overview"}),
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
        resolve(app.clone(), json!({"route": "$/system::context/overview"}),)
            .await
            .status(),
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        resolve(
            app,
            json!({"route": "$/system::context/contexts::missing/overview"}),
        )
        .await
        .status(),
        StatusCode::NOT_FOUND
    );
}

#[tokio::test]
async fn resolves_a_command_runs_collection_with_shared_kind_identity_and_local_route() {
    let fixture = Fixture::new();
    runs_surface(&fixture);
    fixture.executable_resource("home/_lib/proj/system/tool", "run.cmd", "");
    runs_reference(&fixture, "home/_lib/proj/system/tool");
    fixture
        .config_store()
        .save(crate::entry_config::EntryConfigRecord::default())
        .expect("ready Entry Config");
    let kind = json!({
        "resource": {"hops": [{"facet": "system", "selector": "runs"}]},
        "facet": "all"
    });
    let source = json!({
        "resource": {"hops": [{"facet": "system", "selector": "tool"}]},
        "facet": "runs"
    });
    let identity = json!({"type": "instance", "kind": kind, "id": "run-01"});
    let collection = json!({
        "protocol": "swawkit.resource-list/v2",
        "source": source.clone(),
        "resources": [{
            "identity": identity.clone(),
            "selector": "run-01",
            "route": {"hops": [
                {"facet": "system", "selector": "tool"},
                {"facet": "runs", "selector": "run-01"}
            ]},
            "facetIds": ["overview", "open"],
            "label": "2026-08-16 00:00:00.000Z",
            "summary": ".tool · exited · CLI · 1 events"
        }]
    });
    let journal = json!({
        "protocol": "swawkit.command-run-journal/v3",
        "id": "run-01"
    });
    let app = facet_app(
        &fixture,
        BTreeMap::from([
            (
                vec![
                    ".runs".to_owned(),
                    "--json".to_owned(),
                    "$/system::tool".to_owned(),
                ],
                serde_json::to_string(&collection).expect("Run collection JSON"),
            ),
            (
                vec![".runs".to_owned(), "--run".to_owned(), "run-01".to_owned()],
                serde_json::to_string(&journal).expect("Run journal JSON"),
            ),
        ]),
    );

    let response = resolve(app.clone(), json!({"route": "$/system::tool/runs"})).await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("Run collection body");
    let document: Value = serde_json::from_slice(&body).expect("Run collection JSON");
    assert_eq!(document["source"], source);
    assert_eq!(document["resources"][0]["identity"], identity);

    let response = resolve(
        app,
        json!({"route": "$/system::tool/runs::run-01/overview"}),
    )
    .await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("Run journal body");
    let document: Value = serde_json::from_slice(&body).expect("Run journal JSON");
    assert_eq!(document["protocol"], "swawkit.command-run-journal/v3");
    assert_eq!(document["id"], "run-01");
}

#[tokio::test]
async fn resolves_the_runs_commands_all_collection_as_a_distinct_global_scope() {
    let fixture = Fixture::new();
    runs_surface(&fixture);
    fixture
        .config_store()
        .save(crate::entry_config::EntryConfigRecord::default())
        .expect("ready Entry Config");
    let source = json!({
        "resource": {"hops": [{"facet": "system", "selector": "runs"}]},
        "facet": "all"
    });
    let identity = json!({"type": "instance", "kind": source.clone(), "id": "run-01"});
    let collection = json!({
        "protocol": "swawkit.resource-list/v2",
        "source": source.clone(),
        "resources": [{
            "identity": identity.clone(),
            "selector": "run-01",
            "route": {"hops": [
                {"facet": "system", "selector": "runs"},
                {"facet": "all", "selector": "run-01"}
            ]},
            "facetIds": ["overview", "open"],
            "label": "2026-08-16 00:00:00.000Z",
            "summary": ".tool · exited · CLI · 1 events"
        }]
    });
    let app = facet_app(
        &fixture,
        BTreeMap::from([(
            vec![".runs".to_owned(), "--json".to_owned()],
            serde_json::to_string(&collection).expect("global Run collection JSON"),
        )]),
    );

    let response = resolve(app, json!({"route": "$/system::runs/all"})).await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("global Run collection body");
    let document: Value = serde_json::from_slice(&body).expect("global Run collection JSON");
    assert_eq!(document["source"], source);
    assert_eq!(document["resources"][0]["identity"], identity);
}

#[tokio::test]
async fn rejects_unknown_facets_and_the_removed_context_specific_routes() {
    let fixture = Fixture::new();
    context_surface(&fixture);
    fixture
        .config_store()
        .save(crate::entry_config::EntryConfigRecord::default())
        .expect("ready Entry Config");
    let app = facet_app(&fixture, BTreeMap::new());

    assert_eq!(
        resolve(app.clone(), json!({"route": "$/system::context/missing"}),)
            .await
            .status(),
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        resolve(app.clone(), json!({"route": "$/system::context/Overview"}),)
            .await
            .status(),
        StatusCode::UNPROCESSABLE_ENTITY
    );
    assert_eq!(
        resolve(
            app.clone(),
            json!({
                "route": "$/system::context/contexts::test/overview",
                "resolver": {"type": "command", "address": ".context/list"}
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
    report_surface(&fixture);
    fixture
        .config_store()
        .save(crate::entry_config::EntryConfigRecord::default())
        .expect("ready Entry Config");
    let app = facet_app(
        &fixture,
        BTreeMap::from([(
            vec![".report/json".to_owned()],
            r#"{"protocol":"fixture.report/v1","value":42}"#.to_owned(),
        )]),
    );

    let response = resolve(app, json!({"route": "$/system::report/status"})).await;
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
async fn stale_host_rejects_executable_facet_queries_with_the_update_code() {
    let fixture = Fixture::new();
    report_surface(&fixture);
    fixture
        .config_store()
        .save(crate::entry_config::EntryConfigRecord::default())
        .expect("ready Entry Config");
    let app = facet_app(
        &fixture,
        BTreeMap::from([(
            vec![".report/json".to_owned()],
            r#"{"protocol":"fixture.report/v1","value":42}"#.to_owned(),
        )]),
    );
    fixture.select_update();

    let response = resolve(app, json!({"route": "$/system::report/status"})).await;
    assert_eq!(response.status(), StatusCode::CONFLICT);
    let body = to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("update error body");
    let document: Value = serde_json::from_slice(&body).expect("update error JSON");
    assert_eq!(
        document["code"],
        crate::server::command_run::RUNTIME_UPDATE_REQUIRED_CODE
    );
}

#[tokio::test]
async fn validates_resource_identity_routes_and_grants_before_using_facets() {
    let fixture = Fixture::new();
    context_surface(&fixture);
    fixture
        .config_store()
        .save(crate::entry_config::EntryConfigRecord::default())
        .expect("ready Entry Config");
    let summary = resource_listing("release-check", "1 command".to_owned(), json!(["overview"]));
    let duplicate_app = facet_app(
        &fixture,
        BTreeMap::from([(
            vec![".context/list".to_owned(), "--json".to_owned()],
            collection_document(json!([summary.clone(), summary])),
        )]),
    );
    assert_eq!(
        resolve(
            duplicate_app,
            json!({"route": "$/system::context/contexts::release-check/overview"}),
        )
        .await
        .status(),
        StatusCode::INTERNAL_SERVER_ERROR
    );

    let mut invalid_route = summary.clone();
    invalid_route["route"]["hops"][1]["selector"] = json!("another-context");
    let invalid_shape_app = facet_app(
        &fixture,
        BTreeMap::from([(
            vec![".context/list".to_owned(), "--json".to_owned()],
            collection_document(json!([invalid_route])),
        )]),
    );
    assert_eq!(
        resolve(
            invalid_shape_app,
            json!({"route": "$/system::context/contexts"}),
        )
        .await
        .status(),
        StatusCode::INTERNAL_SERVER_ERROR
    );

    let invalid_target_app = facet_app(
        &fixture,
        BTreeMap::from([(
            vec![".context/list".to_owned(), "--json".to_owned()],
            collection_document(json!([resource_listing(
                "release-check",
                "1 command".to_owned(),
                json!(["missing"]),
            )])),
        )]),
    );
    assert_eq!(
        resolve(
            invalid_target_app,
            json!({"route": "$/system::context/contexts"}),
        )
        .await
        .status(),
        StatusCode::INTERNAL_SERVER_ERROR
    );
}
