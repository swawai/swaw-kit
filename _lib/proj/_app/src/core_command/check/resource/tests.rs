use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use swawkit_proj_protocol::{CommandIdentity, command_data_root};

use super::{ResourceErrorKind, ResourceOutcome, inspect_provider_export_directory};
use crate::catalog::{CATALOG_PROTOCOL, CatalogSnapshot, CommandNode, CommandProvision};

static FIXTURE_SEQUENCE: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    root: PathBuf,
    data_root: PathBuf,
}

impl Fixture {
    fn new(name: &str) -> Self {
        let sequence = FIXTURE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "swawkit-provider-resource-{name}-{}-{sequence}",
            std::process::id()
        ));
        let data_root = root.join("data/proj.fixture");
        fs::create_dir_all(&data_root).expect("create fixture Entry DataRoot");
        Self { root, data_root }
    }

    fn provider_root(&self, address: &str) -> PathBuf {
        command_data_root(
            &self.data_root,
            &CommandIdentity::parse(address).expect("fixture provider identity"),
        )
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn distinguishes_ready_missing_and_not_directory_without_leaking_paths() {
    let absent = Fixture::new("missing-provider-root");
    let snapshot = snapshot(vec![provider(".dev/setup", None, true)]);
    let missing_root =
        inspect_provider_export_directory(&snapshot, &absent.data_root, ".dev/setup::export/msvc")
            .unwrap();
    assert_eq!(missing_root.outcome(), ResourceOutcome::Missing);

    let fixture = Fixture::new("outcomes");
    let export = fixture.provider_root(".dev/setup").join("export");
    fs::create_dir_all(export.join("msvc")).unwrap();
    fs::write(export.join("environment.json"), b"{}").unwrap();

    let ready =
        inspect_provider_export_directory(&snapshot, &fixture.data_root, ".dev/setup::export/msvc")
            .unwrap();
    assert_eq!(ready.canonical_locator(), ".dev/setup::export/msvc");
    assert_eq!(ready.outcome(), ResourceOutcome::ReadyDirectory);
    assert_eq!(ready.diagnostic(), None);

    let missing =
        inspect_provider_export_directory(&snapshot, &fixture.data_root, ".dev/setup::export/rust")
            .unwrap();
    assert_eq!(missing.outcome(), ResourceOutcome::Missing);
    assert_eq!(missing.diagnostic(), None);

    let file = inspect_provider_export_directory(
        &snapshot,
        &fixture.data_root,
        ".dev/setup::export/environment.json",
    )
    .unwrap();
    assert_eq!(
        file.canonical_locator(),
        ".dev/setup::export/environment.json"
    );
    assert_eq!(file.outcome(), ResourceOutcome::NotDirectory);
    assert!(file.diagnostic().unwrap().contains("not a directory"));
    assert!(!format!("{ready:?}").contains(&fixture.root.display().to_string()));
}

#[test]
fn rejects_noncanonical_or_unsafe_locator_syntax_as_arguments() {
    let fixture = Fixture::new("invalid-locators");
    let snapshot = snapshot(vec![provider(".dev/setup", None, true)]);
    for invalid in [
        "",
        ".dev/setup",
        ".dev.setup::export/msvc",
        ".dev/setup::state/msvc",
        ".dev/setup::export/",
        ".dev/setup::export/msvc//bin",
        ".dev/setup::export/.",
        ".dev/setup::export/..",
        ".dev/setup::export/msvc\\bin",
        ".dev/setup::export/C:/Windows",
        ".dev/setup::export/file:stream",
        ".dev/setup::export/trailing.",
        ".dev/setup::export/trailing ",
        ".dev/setup::export/control\nname",
        ".dev/setup::export/msvc::bin",
    ] {
        let error = inspect_provider_export_directory(&snapshot, &fixture.data_root, invalid)
            .expect_err(invalid);
        assert_eq!(error.kind(), ResourceErrorKind::Arguments, "{invalid}");
    }
}

#[test]
fn requires_one_canonical_catalog_provider_with_a_declared_export() {
    let fixture = Fixture::new("provider-contract");
    let mut non_runnable = provider(".dev/setup", None, true);
    non_runnable.runnable = false;
    let cases = [
        snapshot(Vec::new()),
        snapshot(vec![provider(
            ".dev/setup",
            Some(".dev/setup-canonical"),
            true,
        )]),
        snapshot(vec![non_runnable]),
        snapshot(vec![provider(".dev/setup", None, false)]),
        snapshot(vec![
            provider(".dev/setup", None, true),
            provider(".dev/setup", None, true),
        ]),
    ];
    for snapshot in cases {
        let error = inspect_provider_export_directory(
            &snapshot,
            &fixture.data_root,
            ".dev/setup::export/msvc",
        )
        .unwrap_err();
        assert_eq!(error.kind(), ResourceErrorKind::Domain);
    }
}

#[test]
fn maps_module_space_through_the_shared_command_identity() {
    let fixture = Fixture::new("module-space");
    let snapshot = snapshot(vec![provider("project/toolchain", None, true)]);
    fs::create_dir_all(
        fixture
            .provider_root("project/toolchain")
            .join("export/sdk"),
    )
    .unwrap();

    let inspection = inspect_provider_export_directory(
        &snapshot,
        &fixture.data_root,
        "project/toolchain::export/sdk",
    )
    .unwrap();

    assert_eq!(inspection.outcome(), ResourceOutcome::ReadyDirectory);
}

#[test]
fn reports_non_directory_ancestors_as_unsafe() {
    let fixture = Fixture::new("unsafe-storage");
    let snapshot = snapshot(vec![provider(".dev/setup", None, true)]);
    let provider_root = fixture.provider_root(".dev/setup");
    fs::create_dir_all(&provider_root).unwrap();
    fs::write(provider_root.join("export"), b"not a directory").unwrap();

    let blocked =
        inspect_provider_export_directory(&snapshot, &fixture.data_root, ".dev/setup::export/msvc")
            .unwrap();
    assert_eq!(blocked.outcome(), ResourceOutcome::Unsafe);
    assert!(blocked.diagnostic().is_some());
}

#[test]
fn rejects_root_ancestor_and_leaf_reparse_points() {
    let fixture = Fixture::new("reparse-storage");
    let snapshot = snapshot(vec![provider(".dev/setup", None, true)]);
    let external = fixture.root.join("external");
    let actual_data_root = external.join("actual-data-root");
    fs::create_dir_all(&actual_data_root).unwrap();
    fs::remove_dir_all(&fixture.data_root).unwrap();
    if let Err(error) = std::os::windows::fs::symlink_dir(&actual_data_root, &fixture.data_root) {
        eprintln!("skipping provider resource reparse assertions: {error}");
        return;
    }
    assert_unsafe(&snapshot, &fixture.data_root, ".dev/setup::export/msvc");
    fs::remove_dir(&fixture.data_root).unwrap();
    fs::create_dir_all(&fixture.data_root).unwrap();

    let provider_root = fixture.provider_root(".dev/setup");
    fs::create_dir_all(&provider_root).unwrap();
    let external_export = external.join("export-root");
    fs::create_dir_all(&external_export).unwrap();
    let export = provider_root.join("export");
    std::os::windows::fs::symlink_dir(&external_export, &export).unwrap();
    assert_unsafe(&snapshot, &fixture.data_root, ".dev/setup::export");
    fs::remove_dir(&export).unwrap();
    fs::create_dir(&export).unwrap();

    let external_ancestor = external.join("ancestor");
    fs::create_dir_all(external_ancestor.join("include")).unwrap();
    let ancestor = export.join("msvc");
    std::os::windows::fs::symlink_dir(&external_ancestor, &ancestor).unwrap();
    assert_unsafe(
        &snapshot,
        &fixture.data_root,
        ".dev/setup::export/msvc/include",
    );
    fs::remove_dir(&ancestor).unwrap();
    fs::create_dir(&ancestor).unwrap();

    let external_leaf = external.join("leaf");
    fs::create_dir(&external_leaf).unwrap();
    let leaf = ancestor.join("include");
    std::os::windows::fs::symlink_dir(&external_leaf, &leaf).unwrap();
    assert_unsafe(
        &snapshot,
        &fixture.data_root,
        ".dev/setup::export/msvc/include",
    );
}

fn assert_unsafe(snapshot: &CatalogSnapshot, data_root: &Path, locator: &str) {
    let inspection = inspect_provider_export_directory(snapshot, data_root, locator).unwrap();
    assert_eq!(inspection.outcome(), ResourceOutcome::Unsafe);
    assert!(inspection.diagnostic().unwrap().contains("reparse point"));
}

fn snapshot(commands: Vec<CommandNode>) -> CatalogSnapshot {
    CatalogSnapshot {
        protocol: CATALOG_PROTOCOL,
        entry_name: "fixture".to_owned(),
        language: "en",
        commands,
    }
}

fn provider(address: &str, alias_of: Option<&str>, declares_export: bool) -> CommandNode {
    let identity = CommandIdentity::parse(address).unwrap();
    CommandNode {
        address: identity.address(),
        space: identity.space(),
        namespace: identity.namespace().map(str::to_owned),
        path: identity.path().to_vec(),
        parent: None,
        alias_of: alias_of.map(str::to_owned),
        runnable: true,
        entry: None,
        adapter: None,
        handler: None,
        product: None,
        requirements: Vec::new(),
        provisions: declares_export
            .then(|| CommandProvision {
                id: "fixture".to_owned(),
            })
            .into_iter()
            .collect(),
        delegate_owner: None,
        declares_native: false,
        declared_facets: Vec::new(),
        declared_resource_kinds: Vec::new(),
        help: None,
        resource_kinds: Vec::new(),
        facets: Vec::new(),
        diagnostic: None,
        authored_resource: true,
        help_diagnostic: None,
        directory: Path::new("fixture-command").to_path_buf(),
        executor_directory: Path::new("fixture-command").to_path_buf(),
        native_owner: None,
    }
}
