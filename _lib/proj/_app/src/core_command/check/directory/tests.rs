use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use serde_json::Value;

use super::*;
use crate::catalog::{
    CATALOG_PROTOCOL, CommandModuleContract, CommandNode, CommandSpace, ModuleProvision,
};

#[test]
fn ready_directory_has_a_frozen_json_document_and_success_exit() {
    let fixture = Fixture::new();
    fs::create_dir_all(fixture.resource("tool")).unwrap();

    let outcome = execute(
        &snapshot(),
        &argv(&[DIRECTORY_EXISTS_ADDRESS, ".provider::export/tool", "--json"]),
        &fixture.data_root,
    )
    .unwrap();
    assert_eq!(outcome.exit_code, 0);
    assert!(outcome.stdout.ends_with('\n'));

    let value: Value = serde_json::from_str(&outcome.stdout).unwrap();
    assert_exact_fields(
        &value,
        &["message", "protocol", "ready", "resource", "status"],
    );
    assert_eq!(value["protocol"], DIRECTORY_EXISTS_PROTOCOL);
    assert_eq!(value["resource"], ".provider::export/tool");
    assert_eq!(value["ready"], true);
    assert_eq!(value["status"], "ready");
    assert_eq!(value["message"], Value::Null);
}

#[test]
fn missing_and_wrong_type_are_normal_failed_checks() {
    let fixture = Fixture::new();
    let missing = execute(
        &snapshot(),
        &argv(&[DIRECTORY_EXISTS_ADDRESS, ".provider::export/missing"]),
        &fixture.data_root,
    )
    .unwrap();
    assert_eq!(missing.exit_code, 1);
    assert!(missing.stdout.contains("Status: missing"));

    let file = fixture.resource("file");
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    fs::write(&file, "not a directory").unwrap();
    let wrong_type = execute(
        &snapshot(),
        &argv(&[DIRECTORY_EXISTS_ADDRESS, ".provider::export/file"]),
        &fixture.data_root,
    )
    .unwrap();
    assert_eq!(wrong_type.exit_code, 1);
    assert!(wrong_type.stdout.contains("Status: not-directory"));
}

#[test]
fn reparse_resource_is_an_unsafe_failed_check() {
    let fixture = Fixture::new();
    let external = fixture.root.join("external");
    let resource = fixture.resource("linked");
    fs::create_dir_all(&external).unwrap();
    fs::create_dir_all(resource.parent().unwrap()).unwrap();
    if std::os::windows::fs::symlink_dir(&external, &resource).is_err() {
        return;
    }

    let outcome = execute(
        &snapshot(),
        &argv(&[DIRECTORY_EXISTS_ADDRESS, ".provider::export/linked"]),
        &fixture.data_root,
    )
    .unwrap();
    assert_eq!(outcome.exit_code, 1);
    assert!(outcome.stdout.contains("Status: unsafe"));
}

#[test]
fn syntax_and_catalog_failures_remain_typed_errors() {
    let fixture = Fixture::new();
    let argument = execute(
        &snapshot(),
        &argv(&[DIRECTORY_EXISTS_ADDRESS, ".provider::export/../escape"]),
        &fixture.data_root,
    )
    .unwrap_err();
    assert!(matches!(argument, CoreCommandError::Arguments { .. }));

    let domain = execute(
        &snapshot(),
        &argv(&[DIRECTORY_EXISTS_ADDRESS, ".missing::export/tool"]),
        &fixture.data_root,
    )
    .unwrap_err();
    assert!(matches!(domain, CoreCommandError::Domain { .. }));

    let usage_error = execute(
        &snapshot(),
        &argv(&[DIRECTORY_EXISTS_ADDRESS]),
        &fixture.data_root,
    )
    .unwrap_err();
    assert!(matches!(usage_error, CoreCommandError::Arguments { .. }));
    assert_eq!(
        usage_error.to_string(),
        "usage: .check/dir/exists <provider>::export[/<path>] [--json]"
    );
}

fn argv(values: &[&str]) -> Vec<OsString> {
    values.iter().map(OsString::from).collect()
}

fn snapshot() -> CatalogSnapshot {
    CatalogSnapshot {
        protocol: CATALOG_PROTOCOL,
        entry_name: "fixture".to_owned(),
        language: "en",
        commands: vec![check_command(), provider_command()],
    }
}

fn check_command() -> CommandNode {
    command(
        DIRECTORY_EXISTS_ADDRESS,
        Some("core"),
        Some(DIRECTORY_EXISTS_HANDLER),
        None,
    )
}

fn provider_command() -> CommandNode {
    command(
        ".provider",
        Some("exe"),
        None,
        Some(CommandModuleContract {
            schema: "swawkit.command-module/v11".to_owned(),
            execution: None,
            requires: Vec::new(),
            provides: vec![ModuleProvision {
                id: "fixture".to_owned(),
                contract: "swawkit.fixture/v1".to_owned(),
            }],
            facets: Vec::new(),
            subject_kinds: Vec::new(),
        }),
    )
}

fn command(
    address: &str,
    adapter: Option<&str>,
    handler: Option<&str>,
    module: Option<CommandModuleContract>,
) -> CommandNode {
    let path = address
        .trim_start_matches('.')
        .split('/')
        .map(str::to_owned)
        .collect::<Vec<_>>();
    CommandNode {
        address: address.to_owned(),
        space: CommandSpace::System,
        namespace: None,
        parent: (path.len() > 1).then(|| format!(".{}", path[..path.len() - 1].join("/"))),
        path,
        alias_of: None,
        runnable: true,
        entry: Some("fixture".to_owned()),
        adapter: adapter.map(str::to_owned),
        handler: handler.map(str::to_owned),
        product: None,
        module,
        help: None,
        subject_kinds: Vec::new(),
        facets: Vec::new(),
        view: None,
        diagnostic: None,
        help_diagnostic: None,
        directory: PathBuf::new(),
        native_owner: None,
    }
}

fn assert_exact_fields(value: &Value, expected: &[&str]) {
    let mut actual = value
        .as_object()
        .expect("document object")
        .keys()
        .map(String::as_str)
        .collect::<Vec<_>>();
    actual.sort_unstable();
    let mut expected = expected.to_vec();
    expected.sort_unstable();
    assert_eq!(actual, expected);
}

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    root: PathBuf,
    data_root: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "swawkit-directory-check-{}-{sequence}",
            std::process::id()
        ));
        let data_root = root.join("data/proj.fixture");
        fs::create_dir_all(&data_root).unwrap();
        Self { root, data_root }
    }

    fn resource(&self, relative: &str) -> PathBuf {
        self.data_root
            .join("modules/system/provider/export")
            .join(relative)
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}
