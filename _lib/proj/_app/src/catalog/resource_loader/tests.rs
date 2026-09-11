use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
};

use swawkit_proj_protocol::{
    FACET_RESULT_RESOURCE, FacetExecution, ResourceFacetKind, ResourceKindManifest, ResourceRoute,
    WebColumnWidth,
};

use super::{load_command_resource, load_resource_tree};

mod requirements;

fn fixture(path: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../_protocol/tests/fixtures/resource-facet")
        .join(path)
}

fn resource(route: &str) -> ResourceRoute {
    ResourceRoute::parse(route).expect("valid fixture Resource route")
}

#[test]
fn loads_the_flat_static_resource_and_facet_tree() {
    let load = load_resource_tree(&fixture("static/dev"), resource("$/system::dev"));
    assert!(load.diagnostics.is_empty(), "{:#?}", load.diagnostics);
    let dev = load.resource.expect("dev Resource");
    assert_eq!(dev.kind, "command");
    assert!(dev.directory.ends_with("dev"));

    let subcommands = facet(&dev, "subcommands");
    assert_eq!(subcommands.kind, ResourceFacetKind::Collection);
    assert!(subcommands.execution.is_none());
    assert!(subcommands.resource_kind.is_none());
    let list = subcommands.resource_list().expect("static Resource List");
    assert_eq!(list.resources().len(), 2);
    assert_eq!(list.resources()[0].selector(), "bun");
    assert_eq!(
        list.resources()[0].route().canonical_route(),
        "$/system::dev/subcommands::bun"
    );
    let bundle = subcommands
        .resolve_web_view(list)
        .expect("resolved Web View Bundle");
    assert_eq!(bundle.view().width, WebColumnWidth::Wide);
    assert!(bundle.resources().contains_key(FACET_RESULT_RESOURCE));

    let bun = &subcommands.resources[0];
    let bun_execute = facet(bun, "execute");
    assert_eq!(bun_execute.local_entry.as_deref(), Some("run.ps1"));
    assert!(bun_execute.execution.is_none());
    assert_eq!(
        bun_execute.requirements.as_ref().unwrap().requirements[0].provider,
        "$/system::dev/subcommands::setup"
    );
    let mode = &facet(bun, "subcommands").resources[0];
    let execute = facet(mode, "execute");
    assert_eq!(execute.kind, ResourceFacetKind::Operation);
    assert!(execute.directory.ends_with("execute"));
    assert!(execute.local_entry.is_none());
    assert!(execute.execution.is_some());
    assert_eq!(
        execute.route.canonical_route(),
        "$/system::dev/subcommands::bun/subcommands::mode/execute"
    );

    let setup = &subcommands.resources[1];
    assert_eq!(setup.selector, "setup");
    assert_eq!(setup.exports.as_ref().unwrap().exports[0].id, "environment");

    let bun_contract = load_command_resource(
        &fixture("static/dev/subcommands/bun"),
        resource("$/system::dev/subcommands::bun"),
        crate::entry_config::EntryLanguage::En,
    );
    assert!(bun_contract.diagnostics.is_empty());
    assert_eq!(bun_contract.requirements[0].provider, ".dev/setup");
    let setup_contract = load_command_resource(
        &fixture("static/dev/subcommands/setup"),
        resource("$/system::dev/subcommands::setup"),
        crate::entry_config::EntryLanguage::En,
    );
    assert!(setup_contract.diagnostics.is_empty());
    assert_eq!(setup_contract.provisions[0].id, "environment");
}

#[test]
fn loads_dynamic_kind_templates_as_invoke_descriptors() {
    let source = load_resource_tree(&fixture("dynamic/context"), resource("$/system::context"));
    assert!(source.diagnostics.is_empty(), "{:#?}", source.diagnostics);
    let context = source.resource.expect("context Resource");
    let contexts = facet(&context, "contexts");
    assert!(matches!(
        contexts.resource_kind,
        Some(ResourceKindManifest::Definition(_))
    ));
    assert!(matches!(
        contexts
            .execution
            .as_ref()
            .map(|execution| &execution.implementation),
        Some(FacetExecution::Invoke { .. })
    ));
    assert_eq!(contexts.templates.len(), 2);
    assert!(contexts.templates.iter().all(|template| {
        template.local_entry.is_none()
            && matches!(
                template
                    .execution
                    .as_ref()
                    .map(|execution| &execution.implementation),
                Some(FacetExecution::Invoke { .. })
            )
    }));
}

#[test]
fn malformed_children_and_views_fail_locally() {
    let fixture = TempFixture::new();
    fixture.write(
        "root/swawkit.resource.json",
        r#"{"schema":"swawkit.resource/v1","kind":"command"}"#,
    );
    fixture.write(
        "root/items/swawkit.facet.json",
        r#"{"schema":"swawkit.facet/v1","kind":"collection"}"#,
    );
    fixture.write("root/items/view/web.json", r#"{"schema":"wrong"}"#);
    fixture.write(
        "root/items/good/swawkit.resource.json",
        r#"{"schema":"swawkit.resource/v1","kind":"command"}"#,
    );
    fs::create_dir_all(fixture.path("root/items/missing-marker")).unwrap();
    fixture.write(
        "root/broken-facet/swawkit.facet.json",
        r#"{"schema":"wrong","kind":"operation"}"#,
    );
    fs::create_dir_all(fixture.path("root/source-assets")).unwrap();

    let load = load_resource_tree(&fixture.path("root"), resource("$/system::root"));
    let root = load.resource.expect("bad children preserve the parent");
    let items = facet(&root, "items");
    assert_eq!(items.resources.len(), 1);
    assert!(items.view.is_none());
    assert!(
        load.diagnostics
            .iter()
            .any(|diagnostic| diagnostic.message.contains("Web View Source"))
    );
    assert!(
        load.diagnostics
            .iter()
            .any(|diagnostic| diagnostic.message.contains("Collection child"))
    );
    assert!(load.diagnostics.iter().any(|diagnostic| {
        diagnostic
            .message
            .contains("unsupported Resource Facet schema")
    }));
}

#[test]
fn noncanonical_protocol_names_are_rejected() {
    let fixture = TempFixture::new();
    fixture.write(
        "root/SWAWKIT.RESOURCE.JSON",
        r#"{"schema":"swawkit.resource/v1","kind":"command"}"#,
    );
    let load = load_resource_tree(&fixture.path("root"), resource("$/system::root"));
    assert!(load.resource.is_none());
    assert_eq!(load.diagnostics.len(), 1);
    assert!(
        load.diagnostics[0]
            .message
            .contains("non-canonical protocol file")
    );
}

#[test]
fn directory_order_and_resource_limits_are_deterministic() {
    let fixture = TempFixture::new();
    fixture.write(
        "ordered/swawkit.resource.json",
        r#"{"schema":"swawkit.resource/v1","kind":"command"}"#,
    );
    fixture.write(
        "ordered/items/swawkit.facet.json",
        r#"{"schema":"swawkit.facet/v1","kind":"collection"}"#,
    );
    for selector in ["z-last", "a-first"] {
        fixture.write(
            &format!("ordered/items/{selector}/swawkit.resource.json"),
            r#"{"schema":"swawkit.resource/v1","kind":"command"}"#,
        );
    }
    let ordered = load_resource_tree(&fixture.path("ordered"), resource("$/system::ordered"));
    let ordered = ordered.resource.unwrap();
    let selectors = facet(&ordered, "items")
        .resources
        .iter()
        .map(|resource| resource.selector.as_str())
        .collect::<Vec<_>>();
    assert_eq!(selectors, ["a-first", "z-last"]);

    fixture.write(
        "oversized/swawkit.resource.json",
        &"x".repeat(64 * 1024 + 1),
    );
    let oversized = load_resource_tree(&fixture.path("oversized"), resource("$/system::oversized"));
    assert!(oversized.resource.is_none());
    assert!(
        oversized
            .diagnostics
            .iter()
            .any(|diagnostic| diagnostic.message.contains("exceeds 65536 bytes"))
    );

    fixture.write(
        "crowded/swawkit.resource.json",
        r#"{"schema":"swawkit.resource/v1","kind":"command"}"#,
    );
    for index in 0..512 {
        fixture.write(&format!("crowded/payload-{index:03}.txt"), "payload");
    }
    let crowded = load_resource_tree(&fixture.path("crowded"), resource("$/system::crowded"));
    assert!(crowded.resource.is_none());
    assert!(
        crowded
            .diagnostics
            .iter()
            .any(|diagnostic| diagnostic.message.contains("more than 512 entries"))
    );
}

#[test]
fn facet_implementation_sources_are_mutually_exclusive() {
    let fixture = TempFixture::new();
    fixture.write(
        "root/swawkit.resource.json",
        r#"{"schema":"swawkit.resource/v1","kind":"command"}"#,
    );
    fixture.write(
        "root/execute/swawkit.facet.json",
        r#"{"schema":"swawkit.facet/v1","kind":"operation"}"#,
    );
    fixture.write("root/execute/run.cmd", "@exit /b 0");
    fixture.write(
        "root/execute/swawkit.execution.json",
        r#"{"schema":"swawkit.facet-execution/v2","implementation":{"type":"native"}}"#,
    );

    let load = load_resource_tree(&fixture.path("root"), resource("$/system::root"));
    let root = load
        .resource
        .expect("execution conflict preserves Resource");
    let execute = facet(&root, "execute");
    assert!(execute.local_entry.is_none());
    assert!(execute.execution.is_none());
    assert!(
        load.diagnostics
            .iter()
            .any(|diagnostic| diagnostic.message.contains("declares both"))
    );

    fixture.write(
        "root/items/swawkit.facet.json",
        r#"{"schema":"swawkit.facet/v1","kind":"collection"}"#,
    );
    fixture.write("root/items/run.cmd", "@exit /b 0");
    fixture.write(
        "root/items/member/swawkit.resource.json",
        r#"{"schema":"swawkit.resource/v1","kind":"command"}"#,
    );
    let load = load_resource_tree(&fixture.path("root"), resource("$/system::root"));
    let root = load.resource.unwrap();
    let items = facet(&root, "items");
    assert!(items.local_entry.is_none());
    assert!(items.resources.is_empty());
    assert!(
        load.diagnostics
            .iter()
            .any(|diagnostic| diagnostic.message.contains("implementation source"))
    );
}

#[test]
fn referenced_resource_kinds_cannot_grow_local_members_or_templates() {
    let fixture = TempFixture::new();
    fixture.write(
        "root/swawkit.resource.json",
        r#"{"schema":"swawkit.resource/v1","kind":"command"}"#,
    );
    fixture.write(
        "root/items/swawkit.facet.json",
        r#"{"schema":"swawkit.facet/v1","kind":"collection"}"#,
    );
    fixture.write(
        "root/items/swawkit.resource-kind.json",
        r#"{"schema":"swawkit.resource-kind/v1","ref":"$/system::runs/all"}"#,
    );
    fixture.write(
        "root/items/swawkit.execution.json",
        r#"{"schema":"swawkit.facet-execution/v2","implementation":{"type":"invoke","target":"$/system::runs/execute"}}"#,
    );
    fixture.write(
        "root/items/local/swawkit.facet.json",
        r#"{"schema":"swawkit.facet/v1","kind":"projection"}"#,
    );
    fixture.write(
        "root/items/member/swawkit.resource.json",
        r#"{"schema":"swawkit.resource/v1","kind":"run"}"#,
    );

    let load = load_resource_tree(&fixture.path("root"), resource("$/system::root"));
    let root = load
        .resource
        .expect("reference preserves its owner Resource");
    let items = facet(&root, "items");
    assert!(matches!(
        items.resource_kind.as_ref(),
        Some(ResourceKindManifest::Reference(_))
    ));
    assert!(items.resources.is_empty());
    assert!(items.templates.is_empty());
    assert_eq!(load.diagnostics.len(), 2, "{:#?}", load.diagnostics);
    assert!(load.diagnostics.iter().all(|diagnostic| {
        diagnostic
            .message
            .contains("referenced Resource Kind cannot")
    }));
}

#[test]
fn command_projection_keeps_direct_implementations_on_execute_facets() {
    let fixture = TempFixture::new();
    fixture.write(
        "root/swawkit.resource.json",
        r#"{"schema":"swawkit.resource/v1","kind":"command"}"#,
    );
    fixture.write(
        "root/action/swawkit.facet.json",
        &facet_manifest("operation", "Action"),
    );
    fixture.write("root/action/run.cmd", "@exit /b 0");

    fixture.write(
        "root/items/swawkit.facet.json",
        &facet_manifest("collection", "Items"),
    );
    fixture.write(
        "root/items/member/swawkit.resource.json",
        r#"{"schema":"swawkit.resource/v1","kind":"command"}"#,
    );

    fixture.write(
        "root/contexts/swawkit.facet.json",
        &facet_manifest("collection", "Contexts"),
    );
    fixture.write(
        "root/contexts/swawkit.resource-kind.json",
        r#"{"schema":"swawkit.resource-kind/v1","kind":"context"}"#,
    );
    fixture.write(
        "root/contexts/swawkit.execution.json",
        r#"{"schema":"swawkit.facet-execution/v2","implementation":{"type":"invoke","target":"$/system::root/execute","returns":"swawkit.resource-list/v2"}}"#,
    );
    fixture.write(
        "root/contexts/archive/swawkit.facet.json",
        &facet_manifest("operation", "Archive"),
    );
    fixture.write("root/contexts/archive/run.cmd", "@exit /b 0");

    let contract = load_command_resource(
        &fixture.path("root"),
        resource("$/system::root"),
        crate::entry_config::EntryLanguage::En,
    );
    assert_eq!(
        contract
            .facets
            .iter()
            .map(|facet| facet.id.as_str())
            .collect::<Vec<_>>(),
        ["contexts"]
    );
    assert!(contract.diagnostics.iter().any(|diagnostic| {
        diagnostic.contains("authored Facet '$/system::root/action'")
            && diagnostic.contains("cannot own a local run.* entry")
    }));
    assert!(contract.diagnostics.iter().any(|diagnostic| {
        diagnostic.contains("authored Facet '$/system::root/items'")
            && diagnostic.contains("only subcommands is a static Collection")
    }));
    assert!(contract.diagnostics.iter().any(|diagnostic| {
        diagnostic.contains("Facet template '$/system::root/contexts::archive'")
            && diagnostic.contains("cannot own a local run.* entry")
    }));
}

fn facet_manifest(kind: &str, label: &str) -> String {
    format!(
        r#"{{"schema":"swawkit.facet/v1","kind":"{kind}","presentation":{{"icon":"x","label":{{"zh-CN":"{label}","en":"{label}"}},"summary":{{"zh-CN":"{label}","en":"{label}"}}}}}}"#
    )
}

fn facet<'a>(resource: &'a super::LoadedResource, id: &str) -> &'a super::LoadedFacet {
    resource
        .facets
        .iter()
        .find(|facet| facet.route.facet() == id)
        .unwrap_or_else(|| panic!("missing Facet {id} below {}", resource.route))
}

struct TempFixture {
    root: PathBuf,
}

impl TempFixture {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let sequence = NEXT.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "swawkit-resource-loader-{}-{sequence}",
            std::process::id()
        ));
        fs::create_dir_all(&root).expect("create Resource Loader fixture");
        Self { root }
    }

    fn path(&self, relative: &str) -> PathBuf {
        self.root.join(relative)
    }

    fn write(&self, relative: &str, contents: &str) {
        let path = self.path(relative);
        fs::create_dir_all(path.parent().expect("fixture parent")).unwrap();
        fs::write(path, contents).unwrap();
    }
}

impl Drop for TempFixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}
