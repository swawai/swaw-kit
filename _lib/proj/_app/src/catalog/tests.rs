use super::*;
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

const SHARED_VALID_FULL: &str =
    include_str!("../../../_protocol/tests/fixtures/command-module/valid-full.json");
const SHARED_INVALID_FACET: &str =
    include_str!("../../../_protocol/tests/fixtures/command-module/invalid-facet.json");
const SHARED_INVALID_SUBJECT_KIND: &str =
    include_str!("../../../_protocol/tests/fixtures/command-module/invalid-subject-kind.json");

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

fn delegate_manifest(owner: &str) -> String {
    format!(
        r#"{{"schema":"swawkit.command-module/v11","execution":{{"type":"delegate","owner":{{"type":"command","space":"module","namespace":"swaw","address":"{owner}"}}}}}}"#
    )
}

fn core_manifest(handler: &str) -> String {
    format!(
        r#"{{"schema":"swawkit.command-module/v11","execution":{{"type":"core","handler":"{handler}"}}}}"#
    )
}

fn runtime_manifest(product: &str) -> String {
    format!(
        r#"{{"schema":"swawkit.command-module/v11","execution":{{"type":"runtime","product":"{product}"}}}}"#
    )
}

fn native_manifest() -> &'static str {
    r#"{"schema":"swawkit.command-module/v11","execution":{"type":"native"}}"#
}

fn module_manifest() -> &'static str {
    r#"{"schema":"swawkit.command-module/v11"}"#
}

#[test]
fn shared_protocol_fixtures_define_catalog_membership() {
    let fixture = Fixture::new();
    fixture.file(
        &fixture.swaw,
        "valid/swawkit.module.json",
        SHARED_VALID_FULL,
    );
    fixture.file(
        &fixture.swaw,
        "invalid-facet/swawkit.module.json",
        SHARED_INVALID_FACET,
    );
    fixture.file(
        &fixture.swaw,
        "invalid-subject-kind/swawkit.module.json",
        SHARED_INVALID_SUBJECT_KIND,
    );

    let snapshot = fixture.discover();
    assert!(node(&snapshot, "swaw/valid").module.is_some());
    for address in ["swaw/invalid-facet", "swaw/invalid-subject-kind"] {
        let command = node(&snapshot, address);
        assert!(command.module.is_none(), "{address}");
        assert!(!command.runnable, "{address}");
        assert!(
            command
                .diagnostic
                .as_deref()
                .is_some_and(|value| value.contains("invalid module contract manifest")),
            "{address}: {:?}",
            command.diagnostic
        );
    }
}

#[test]
fn discovers_system_and_explicit_module_namespaces() {
    let fixture = Fixture::new();
    fixture.file(
        &fixture.system,
        "entry/swawkit.module.json",
        &core_manifest("entry.profile"),
    );
    fixture.file(
        &fixture.system,
        "entry/language/swawkit.module.json",
        &core_manifest("entry.profile.set"),
    );
    fixture.file(
        &fixture.swaw,
        "context/swawkit.module.json",
        native_manifest(),
    );
    fixture.file(
        &fixture.system,
        "dev/swawkit.module.json",
        module_manifest(),
    );
    fixture.file(
        &fixture.system,
        "dev/setup/swawkit.module.json",
        &runtime_manifest("dev"),
    );
    fixture.file(
        &fixture.swaw,
        "context/add/swawkit.module.json",
        &delegate_manifest("swaw/context"),
    );
    fixture.file(
        &fixture.project,
        "build/swawkit.module.json",
        module_manifest(),
    );
    fixture.file(&fixture.project, "build/run.ps1", "exit 0");

    let snapshot = fixture.discover();
    let identities = snapshot
        .commands
        .iter()
        .map(|node| (node.space, node.namespace.as_deref(), node.address.as_str()))
        .collect::<Vec<_>>();

    assert!(identities.contains(&(CommandSpace::System, None, "")));
    assert!(identities.contains(&(CommandSpace::System, None, ".entry")));
    assert!(identities.contains(&(CommandSpace::System, None, ".entry/language")));
    assert!(identities.contains(&(CommandSpace::System, None, ".dev/setup")));
    assert!(identities.contains(&(CommandSpace::Module, Some("swaw"), "swaw")));
    assert!(identities.contains(&(CommandSpace::Module, Some("swaw"), "swaw/context")));
    assert!(identities.contains(&(CommandSpace::Module, Some("project"), "project")));
    assert!(identities.contains(&(CommandSpace::Module, Some("project"), "project/build")));

    let context = node(&snapshot, "swaw/context");
    let entry = node(&snapshot, ".entry");
    assert_eq!(entry.entry.as_deref(), Some("swawkit.module.json"));
    assert_eq!(entry.adapter.as_deref(), Some("core"));
    assert_eq!(entry.handler.as_deref(), Some("entry.profile"));
    let setup = node(&snapshot, ".dev/setup");
    assert_eq!(setup.entry.as_deref(), Some("swawkit.module.json"));
    assert_eq!(setup.adapter.as_deref(), Some("runtime"));
    assert_eq!(setup.handler, None);
    assert_eq!(setup.product.as_deref(), Some("dev"));
    assert_eq!(context.entry.as_deref(), Some("swawkit.module.json"));
    assert_eq!(context.adapter.as_deref(), Some("native"));
    assert_eq!(context.native_owner.as_deref(), Some("swaw/context"));
    assert_eq!(
        node(&snapshot, "swaw/context/add").native_owner.as_deref(),
        Some("swaw/context")
    );
}

#[test]
fn system_commands_can_own_native_execution() {
    let fixture = Fixture::new();
    fixture.file(
        &fixture.system,
        "native/swawkit.module.json",
        native_manifest(),
    );

    let snapshot = fixture.discover();
    let command = node(&snapshot, ".native");
    assert!(command.runnable, "{:?}", command.diagnostic);
    assert_eq!(command.adapter.as_deref(), Some("native"));
    assert_eq!(command.native_owner.as_deref(), Some(".native"));
}

#[test]
fn core_execution_handlers_remain_exact_and_system_owned() {
    let fixture = Fixture::new();
    fixture.file(
        &fixture.system,
        "check/swawkit.module.json",
        &core_manifest("meta.check"),
    );
    fixture.file(
        &fixture.system,
        "check/dir/swawkit.module.json",
        module_manifest(),
    );
    fixture.file(
        &fixture.system,
        "check/dir/exists/swawkit.module.json",
        &core_manifest("meta.check.dir.exists"),
    );
    fixture.file(
        &fixture.system,
        "wrong-core/swawkit.module.json",
        &core_manifest("meta.help"),
    );
    fixture.file(
        &fixture.swaw,
        "wrong-space/swawkit.module.json",
        &core_manifest("meta.help"),
    );

    let snapshot = fixture.discover();
    let directory_check = node(&snapshot, ".check/dir/exists");
    assert!(directory_check.runnable, "{:?}", directory_check.diagnostic);
    assert_eq!(directory_check.adapter.as_deref(), Some("core"));
    assert_eq!(
        directory_check.handler.as_deref(),
        Some("meta.check.dir.exists")
    );
    for address in [".wrong-core", "swaw/wrong-space"] {
        let command = node(&snapshot, address);
        assert!(!command.runnable, "{address}");
        assert!(
            command
                .diagnostic
                .as_deref()
                .is_some_and(|message| message.contains("exact System command owner")),
            "{address}: {:?}",
            command.diagnostic
        );
    }
}

#[test]
fn runtime_components_are_exact_and_have_no_handler() {
    let fixture = Fixture::new();
    fixture.file(
        &fixture.system,
        "module/swawkit.module.json",
        module_manifest(),
    );
    fixture.file(
        &fixture.system,
        "module/instantiate/swawkit.module.json",
        r#"{"schema":"swawkit.command-module/v11","execution":{"type":"runtime","product":"module"}}"#,
    );
    fixture.file(
        &fixture.system,
        "module/status/swawkit.module.json",
        &runtime_manifest("module"),
    );
    fixture.file(
        &fixture.system,
        "dev/swawkit.module.json",
        module_manifest(),
    );
    fixture.file(
        &fixture.system,
        "dev/setup/swawkit.module.json",
        &runtime_manifest("dev"),
    );
    fixture.file(
        &fixture.system,
        "dev/status/swawkit.module.json",
        &runtime_manifest("dev"),
    );
    fixture.file(
        &fixture.system,
        "dev/setup/check/swawkit.module.json",
        &runtime_manifest("dev"),
    );
    fixture.file(
        &fixture.system,
        "wrong-runtime/swawkit.module.json",
        &runtime_manifest("module"),
    );
    fixture.file(
        &fixture.swaw,
        "wrong-runtime/swawkit.module.json",
        &runtime_manifest("module"),
    );
    fixture.file(
        &fixture.system,
        "module/wrong-product/swawkit.module.json",
        &runtime_manifest("toolchain"),
    );

    let snapshot = fixture.discover();
    for (address, product) in [
        (".module/instantiate", "module"),
        (".module/status", "module"),
        (".dev/setup", "dev"),
        (".dev/setup/check", "dev"),
        (".dev/status", "dev"),
    ] {
        let command = node(&snapshot, address);
        assert!(command.runnable, "{address}: {:?}", command.diagnostic);
        assert_eq!(command.adapter.as_deref(), Some("runtime"));
        assert_eq!(command.product.as_deref(), Some(product));
        assert_eq!(command.handler, None);
    }
    for address in [".module/instantiate", ".module/status"] {
        assert!(
            node(&snapshot, address)
                .module
                .as_ref()
                .expect("module manager contract")
                .requires
                .is_empty()
        );
    }
    for address in [
        ".wrong-runtime",
        "swaw/wrong-runtime",
        ".module/wrong-product",
    ] {
        let command = node(&snapshot, address);
        assert!(!command.runnable, "{address}");
        assert!(
            command
                .diagnostic
                .as_deref()
                .is_some_and(|message| message.contains("Runtime Component")),
            "{address}: {:?}",
            command.diagnostic
        );
    }
}

#[test]
fn private_and_noncanonical_directories_do_not_become_commands() {
    let fixture = Fixture::new();
    fixture.file(
        &fixture.system,
        "_private/swawkit.module.json",
        module_manifest(),
    );
    fixture.file(&fixture.system, "_private/run.ps1", "exit 0");
    fixture.file(
        &fixture.system,
        "Bad/swawkit.module.json",
        module_manifest(),
    );
    fixture.file(&fixture.system, "Bad/run.ps1", "exit 0");
    fixture.file(
        &fixture.project,
        "build_ok/swawkit.module.json",
        module_manifest(),
    );
    fixture.file(&fixture.project, "build_ok/run.ps1", "exit 0");

    let snapshot = fixture.discover();
    assert_eq!(
        snapshot
            .commands
            .iter()
            .map(|node| node.address.as_str())
            .collect::<Vec<_>>(),
        ["", "project", "swaw"]
    );
}

#[test]
fn discovery_is_limited_to_the_fixed_swaw_and_project_roots() {
    let fixture = Fixture::new();
    fixture.file(
        &fixture.swaw,
        "release/swawkit.module.json",
        module_manifest(),
    );
    fixture.file(
        &fixture.project,
        "build/swawkit.module.json",
        module_manifest(),
    );
    let external = fixture.root.join("external/acme");
    fixture.file(&external, "hidden/swawkit.module.json", module_manifest());

    let snapshot = fixture.discover();

    assert!(
        snapshot
            .commands
            .iter()
            .any(|node| node.address == "swaw/release")
    );
    assert!(
        snapshot
            .commands
            .iter()
            .any(|node| node.address == "project/build")
    );
    assert!(
        snapshot
            .commands
            .iter()
            .all(|node| node.address != "acme/hidden")
    );
}

#[test]
fn module_contract_provider_addresses_use_the_new_cli_grammar() {
    let fixture = Fixture::new();
    fixture.file(
        &fixture.swaw,
        "producer/swawkit.module.json",
        r#"{"schema":"swawkit.command-module/v11","provides":[{"id":"fixture","contract":"fixture/v1"}]}"#,
    );
    fixture.file(
        &fixture.swaw,
        "consumer/swawkit.module.json",
        r#"{"schema":"swawkit.command-module/v11","requires":[{"provider":"swaw/producer","export":"fixture","contract":"fixture/v1"}]}"#,
    );
    fixture.file(
        &fixture.swaw,
        "legacy/swawkit.module.json",
        r#"{"schema":"swawkit.command-module/v11","requires":[{"provider":".dev.setup","export":"fixture","contract":"fixture/v1"}]}"#,
    );

    let snapshot = fixture.discover();
    assert_eq!(
        node(&snapshot, "swaw/consumer")
            .module
            .as_ref()
            .unwrap()
            .requires[0]
            .provider,
        "swaw/producer"
    );
    assert!(
        node(&snapshot, "swaw/legacy")
            .diagnostic
            .as_deref()
            .is_some_and(|message| message.contains("provider"))
    );
}

#[test]
fn explicit_delegate_owner_does_not_depend_on_intermediate_entries() {
    let fixture = Fixture::new();
    fixture.file(
        &fixture.swaw,
        "domain/swawkit.module.json",
        native_manifest(),
    );
    fixture.file(
        &fixture.swaw,
        "domain/a/swawkit.module.json",
        &delegate_manifest("swaw/domain"),
    );
    fixture.file(
        &fixture.swaw,
        "domain/a/b/swawkit.module.json",
        &delegate_manifest("swaw/domain"),
    );

    let snapshot = fixture.discover();
    for address in ["swaw/domain/a", "swaw/domain/a/b"] {
        let command = node(&snapshot, address);
        assert!(command.runnable, "{:?}", command.diagnostic);
        assert_eq!(command.adapter.as_deref(), Some("delegate"));
        assert_eq!(command.native_owner.as_deref(), Some("swaw/domain"));
    }
}

#[test]
fn delegate_cannot_cross_a_conflicting_nested_native_declaration() {
    let fixture = Fixture::new();
    fixture.file(
        &fixture.swaw,
        "domain/swawkit.module.json",
        native_manifest(),
    );
    fixture.file(
        &fixture.swaw,
        "domain/child/swawkit.module.json",
        native_manifest(),
    );
    fixture.file(&fixture.swaw, "domain/child/run.ts", "");
    fixture.file(
        &fixture.swaw,
        "domain/child/port/swawkit.module.json",
        &delegate_manifest("swaw/domain"),
    );

    let snapshot = fixture.discover();
    assert!(
        node(&snapshot, "swaw/domain/child")
            .diagnostic
            .as_deref()
            .is_some_and(|message| message.contains("both a local run.* entry"))
    );
    let command = node(&snapshot, "swaw/domain/child/port");
    assert_eq!(command.entry, None);
    assert_eq!(command.adapter, None);
    assert!(
        command
            .diagnostic
            .as_deref()
            .is_some_and(|message| message.contains("cannot cross nested native owner")),
        "{:?}",
        command.diagnostic
    );
}

#[test]
fn delegated_execution_requires_one_real_native_ancestor() {
    let fixture = Fixture::new();
    fixture.file(
        &fixture.swaw,
        "script/swawkit.module.json",
        module_manifest(),
    );
    fixture.file(&fixture.swaw, "script/run.ts", "");
    fixture.file(
        &fixture.swaw,
        "script/port/swawkit.module.json",
        &delegate_manifest("swaw/script"),
    );
    fixture.file(
        &fixture.swaw,
        "sibling/swawkit.module.json",
        native_manifest(),
    );
    fixture.file(
        &fixture.swaw,
        "script/non-ancestor/swawkit.module.json",
        &delegate_manifest("swaw/sibling"),
    );
    fixture.file(&fixture.swaw, "conflict/run.ts", "");
    fixture.file(
        &fixture.swaw,
        "conflict/swawkit.module.json",
        native_manifest(),
    );

    let snapshot = fixture.discover();
    assert!(
        node(&snapshot, "swaw/script/port")
            .diagnostic
            .as_deref()
            .is_some_and(|message| message.contains("must declare native execution"))
    );
    assert_eq!(node(&snapshot, "swaw/script/port").entry, None);
    assert_eq!(node(&snapshot, "swaw/script/port").adapter, None);
    assert!(
        node(&snapshot, "swaw/script/non-ancestor")
            .diagnostic
            .as_deref()
            .is_some_and(|message| message.contains("must be an ancestor"))
    );
    assert!(
        node(&snapshot, "swaw/conflict")
            .diagnostic
            .as_deref()
            .is_some_and(|message| message.contains("both a local run.* entry"))
    );
}

#[test]
fn obsolete_entries_and_v8_module_contract_fail_explicitly() {
    let fixture = Fixture::new();
    for (directory, entry) in [
        ("legacy-core", "run.core.json"),
        ("legacy-toolchain", "run.toolchain.json"),
        ("legacy-native", "run.native"),
        ("legacy-delegate", "run.delegate"),
    ] {
        fixture.file(
            &fixture.swaw,
            &format!("{directory}/swawkit.module.json"),
            module_manifest(),
        );
        fixture.file(&fixture.swaw, &format!("{directory}/{entry}"), "");
    }
    fixture.file(
        &fixture.swaw,
        "legacy-contract/swawkit.module.json",
        r#"{"schema":"swawkit.command-module/v8","provides":[{"id":"fixture","contract":"fixture/v1"}]}"#,
    );

    let snapshot = fixture.discover();
    for address in [
        "swaw/legacy-core",
        "swaw/legacy-toolchain",
        "swaw/legacy-native",
        "swaw/legacy-delegate",
    ] {
        assert!(
            node(&snapshot, address)
                .diagnostic
                .as_deref()
                .is_some_and(|message| message.contains("obsolete command entry")),
            "{address}"
        );
    }
    assert!(
        node(&snapshot, "swaw/legacy-contract")
            .diagnostic
            .as_deref()
            .is_some_and(|message| message.contains("unsupported module contract schema"))
    );
}

#[test]
fn only_the_branded_manifest_grants_module_identity() {
    let fixture = Fixture::new();
    fixture.file(
        &fixture.swaw,
        "foreign/_module.json",
        r#"{"schema":"another.module/v1"}"#,
    );
    fixture.file(
        &fixture.swaw,
        "ordinary/nested/swawkit.module.json",
        module_manifest(),
    );
    fixture.file(&fixture.swaw, "broken/swawkit.module.json", "{");

    let snapshot = fixture.discover();
    assert!(snapshot.commands.iter().all(|command| {
        command.address != "swaw/foreign"
            && command.address != "swaw/ordinary"
            && command.address != "swaw/ordinary/nested"
    }));
    let broken = node(&snapshot, "swaw/broken");
    assert!(!broken.runnable);
    assert!(
        broken
            .diagnostic
            .as_deref()
            .is_some_and(|message| message.contains("invalid module contract manifest"))
    );
}

#[test]
fn selects_entry_language_help_and_falls_back_to_chinese() {
    let fixture = Fixture::new();
    fixture.file(
        &fixture.system,
        "translated/swawkit.module.json",
        module_manifest(),
    );
    fixture.file(&fixture.system, "translated/_help/zh-CN.txt", "中文摘要");
    fixture.file(
        &fixture.system,
        "translated/_help/en.txt",
        "English summary",
    );
    fixture.file(&fixture.system, "fallback/_help/zh-CN.txt", "中文回退");

    fixture.file(
        &fixture.system,
        "fallback/swawkit.module.json",
        module_manifest(),
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
            .map(|help| help.summary.as_str()),
        Some("English summary")
    );
    assert_eq!(
        node(&snapshot, ".fallback")
            .help
            .as_ref()
            .map(|help| help.summary.as_str()),
        Some("中文回退")
    );
}

fn node<'a>(snapshot: &'a CatalogSnapshot, address: &str) -> &'a CommandNode {
    snapshot
        .commands
        .iter()
        .find(|node| node.address == address)
        .unwrap_or_else(|| panic!("missing node {address}"))
}

mod native_system;
