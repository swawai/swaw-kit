use super::*;
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

const RESOURCE: &str = r#"{"schema":"swawkit.resource/v1","kind":"command"}"#;
const COLLECTION: &str = r#"{"schema":"swawkit.facet/v1","kind":"collection"}"#;
const OPERATION: &str = r#"{"schema":"swawkit.facet/v1","kind":"operation"}"#;

struct Fixture {
    root: PathBuf,
    system: PathBuf,
    swaw: PathBuf,
    project: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let root =
            std::env::temp_dir().join(format!("swawkit-catalog-{}-{sequence}", std::process::id()));
        let system = root.join("home/_lib/proj/system");
        let swaw = root.join("home/_lib/proj/modules");
        let project = root.join("project/.swaw");
        for path in [&system, &swaw, &project] {
            fs::create_dir_all(path).expect("create fixture command root");
        }
        Self {
            root,
            system,
            swaw,
            project,
        }
    }

    fn file(&self, root: &Path, relative: &str, text: &str) {
        let path = root.join(relative);
        fs::create_dir_all(path.parent().expect("fixture file parent"))
            .expect("create fixture file parent");
        fs::write(path, text).expect("write fixture file");
    }

    fn resource(&self, root: &Path, relative: &str) {
        self.file(root, &format!("{relative}/swawkit.resource.json"), RESOURCE);
    }

    fn child_resource(&self, root: &Path, parent: &str, child: &str) {
        self.resource(root, parent);
        self.file(
            root,
            &format!("{parent}/subcommands/swawkit.facet.json"),
            COLLECTION,
        );
        self.resource(root, &format!("{parent}/subcommands/{child}"));
    }

    fn executable(&self, root: &Path, relative: &str) {
        self.resource(root, relative);
        self.file(
            root,
            &format!("{relative}/execute/swawkit.facet.json"),
            OPERATION,
        );
        self.file(root, &format!("{relative}/execute/run.ps1"), "exit 0");
    }

    fn discover(&self) -> CatalogSnapshot {
        CatalogSnapshot::discover_roots(&self.system, &self.swaw, &self.project, "fixture")
            .expect("discover fixture catalog")
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn resources_and_collection_members_define_command_identity() {
    let fixture = Fixture::new();
    fixture.file(&fixture.system, "run.ps1", "exit 0");
    fixture.child_resource(&fixture.system, "dev", "bun");
    fixture.file(
        &fixture.system,
        "dev/subcommands/bun/subcommands/swawkit.facet.json",
        COLLECTION,
    );
    fixture.executable(&fixture.system, "dev/subcommands/bun/subcommands/version");
    fixture.executable(&fixture.swaw, "build");
    fixture.executable(&fixture.project, "publish");

    let snapshot = fixture.discover();
    assert_eq!(snapshot.protocol, "swawkit.command-catalog/v24");
    assert!(node(&snapshot, "").runnable);
    assert!(!node(&snapshot, ".dev").runnable);
    assert!(!node(&snapshot, ".dev/bun").runnable);
    let version = node(&snapshot, ".dev/bun/version");
    assert!(version.runnable);
    assert_eq!(version.entry.as_deref(), Some("run.ps1"));
    assert!(version.executor_directory.ends_with("version/execute"));
    assert!(node(&snapshot, "swaw/build").runnable);
    assert!(node(&snapshot, "project/publish").runnable);
}

#[test]
fn old_module_documents_do_not_grant_catalog_membership() {
    let fixture = Fixture::new();
    fixture.file(
        &fixture.system,
        "legacy/swawkit.module.json",
        r#"{"schema":"swawkit.command-module/v12"}"#,
    );
    fixture.file(&fixture.system, "legacy/run.ps1", "exit 0");
    fixture.resource(&fixture.system, "resource");

    let snapshot = fixture.discover();
    assert!(
        snapshot
            .commands
            .iter()
            .all(|node| node.address != ".legacy")
    );
    assert!(
        snapshot
            .commands
            .iter()
            .any(|node| node.address == ".resource")
    );
}

#[test]
fn resource_owns_traversal_and_does_not_leak_ordinary_directories() {
    let fixture = Fixture::new();
    fixture.resource(&fixture.system, "group");
    fixture.executable(&fixture.system, "group/ordinary");

    let snapshot = fixture.discover();
    assert!(
        snapshot
            .commands
            .iter()
            .any(|node| node.address == ".group")
    );
    assert!(
        snapshot
            .commands
            .iter()
            .all(|node| node.address != ".group/ordinary")
    );
}

#[test]
fn invalid_resource_is_visible_but_not_runnable() {
    let fixture = Fixture::new();
    fixture.file(
        &fixture.system,
        "broken/swawkit.resource.json",
        r#"{"schema":"wrong/v1","kind":"command"}"#,
    );

    let broken = node(&fixture.discover(), ".broken").clone();
    assert!(!broken.runnable);
    assert!(
        broken
            .diagnostic
            .as_deref()
            .is_some_and(|value| value.contains("schema"))
    );
}

#[test]
fn help_is_read_from_the_resource_and_falls_back_to_chinese() {
    let fixture = Fixture::new();
    fixture.resource(&fixture.system, "translated");
    fixture.file(
        &fixture.system,
        "translated/_help/en.txt",
        "English summary\n{{INVOCATION}}",
    );
    fixture.resource(&fixture.system, "fallback");
    fixture.file(
        &fixture.system,
        "fallback/_help/zh-CN.txt",
        "中文回退\n{{ADDRESS}}",
    );

    let snapshot = CatalogSnapshot::discover_roots_in_language(
        &fixture.system,
        &fixture.swaw,
        &fixture.project,
        "fixture",
        EntryLanguage::En,
    )
    .unwrap();
    assert_eq!(
        node(&snapshot, ".translated")
            .help
            .as_ref()
            .map(|help| help.text.as_str()),
        Some("English summary\nfixture .translated")
    );
    assert_eq!(
        node(&snapshot, ".fallback")
            .help
            .as_ref()
            .map(|help| help.text.as_str()),
        Some("中文回退\n.fallback")
    );
}

#[test]
fn discovery_is_limited_to_explicit_roots() {
    let fixture = Fixture::new();
    fixture.resource(&fixture.swaw, "kept");
    let external = fixture.root.join("external");
    fs::create_dir_all(&external).unwrap();
    fixture.resource(&external, "hidden");

    let snapshot = fixture.discover();
    assert!(
        snapshot
            .commands
            .iter()
            .any(|node| node.address == "swaw/kept")
    );
    assert!(
        snapshot
            .commands
            .iter()
            .all(|node| node.address != "swaw/hidden")
    );
}

#[test]
fn resource_kind_refs_resolve_exact_definitions_and_reject_chains() {
    let fixture = Fixture::new();
    fixture.executable(&fixture.system, "runs");
    fixture.file(
        &fixture.system,
        "runs/all/swawkit.facet.json",
        r#"{"schema":"swawkit.facet/v1","kind":"collection","presentation":{"icon":"=","label":{"zh-CN":"全部","en":"All"},"summary":{"zh-CN":"全部运行","en":"All runs"}}}"#,
    );
    fixture.file(
        &fixture.system,
        "runs/all/swawkit.resource-kind.json",
        r#"{"schema":"swawkit.resource-kind/v1","kind":"run"}"#,
    );
    fixture.file(
        &fixture.system,
        "runs/all/swawkit.execution.json",
        r#"{"schema":"swawkit.facet-execution/v2","implementation":{"type":"invoke","target":"$/system::runs/execute"}}"#,
    );
    fixture.file(
        &fixture.system,
        "runs/all/overview/swawkit.facet.json",
        r#"{"schema":"swawkit.facet/v1","kind":"projection","presentation":{"icon":"i","label":{"zh-CN":"详情","en":"Overview"},"summary":{"zh-CN":"查看运行","en":"Inspect run"}}}"#,
    );
    fixture.file(
        &fixture.system,
        "runs/all/overview/swawkit.execution.json",
        r#"{"schema":"swawkit.facet-execution/v2","implementation":{"type":"invoke","target":"$/system::runs/execute","arguments":[{"bind":"resource.selector"}],"returns":"fixture.run/v1"}}"#,
    );

    for (resource, target) in [
        ("tool", "$/system::runs/all"),
        ("chained", "$/system::tool/runs"),
        ("missing", "$/system::absent/items"),
    ] {
        fixture.executable(&fixture.system, resource);
        fixture.file(
            &fixture.system,
            &format!("{resource}/runs/swawkit.facet.json"),
            r#"{"schema":"swawkit.facet/v1","kind":"collection","presentation":{"icon":"=","label":{"zh-CN":"运行","en":"Runs"},"summary":{"zh-CN":"查看运行","en":"Browse runs"}}}"#,
        );
        fixture.file(
            &fixture.system,
            &format!("{resource}/runs/swawkit.resource-kind.json"),
            &format!(r#"{{"schema":"swawkit.resource-kind/v1","ref":"{target}"}}"#),
        );
        fixture.file(
            &fixture.system,
            &format!("{resource}/runs/swawkit.execution.json"),
            r#"{"schema":"swawkit.facet-execution/v2","implementation":{"type":"invoke","target":"$/system::runs/execute"}}"#,
        );
    }

    let snapshot = fixture.discover();
    let tool = node(&snapshot, ".tool");
    let runs = tool
        .facets
        .iter()
        .find(|facet| facet.id == "runs")
        .expect("exact Resource Kind ref");
    let kind = runs.resource_kind.as_ref().expect("resolved Resource Kind");
    assert_eq!(kind.source.to_string(), "$/system::runs/all");
    assert!(tool.diagnostic.is_none(), "{:?}", tool.diagnostic);

    for address in [".chained", ".missing"] {
        let diagnostic = node(&snapshot, address)
            .diagnostic
            .as_deref()
            .expect("invalid ref diagnostic");
        assert!(diagnostic.contains("must target one local definition"));
        assert!(
            node(&snapshot, address)
                .facets
                .iter()
                .all(|facet| facet.id != "runs")
        );
    }
}

fn node<'a>(snapshot: &'a CatalogSnapshot, address: &str) -> &'a CommandNode {
    snapshot
        .commands
        .iter()
        .find(|node| node.address == address)
        .unwrap_or_else(|| panic!("missing node {address}"))
}
