use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use serde_json::{Value, json};

use super::*;
use crate::catalog::{
    CATALOG_PROTOCOL, CommandModuleContract, MODULE_CONTRACT_PROTOCOL, ModuleProvision,
};

const CONTRACT: &str = "swawkit.fixture/v1";
static NEXT_ROOT: AtomicU64 = AtomicU64::new(0);

#[test]
fn provider_own_publications_do_not_affect_its_readiness_or_wire_shape() {
    let snapshot = snapshot(vec![command(
        ".provider",
        Vec::new(),
        vec![provision("fixture", CONTRACT)],
    )]);

    let document = inspect(Path::new("unused"), "swawkit", &snapshot, ".provider").unwrap();
    let value = serde_json::to_value(&document).unwrap();

    assert!(document.ready);
    assert!(document.dependencies.is_empty());
    assert_eq!(document.protocol, "swawkit.command-check/v1");
    assert_exact_fields(&value, &["protocol", "command", "dependencies", "ready"]);
    assert_exact_fields(
        &value["command"],
        &[
            "address",
            "space",
            "namespace",
            "runnable",
            "adapter",
            "diagnostic",
        ],
    );
}

#[test]
fn recursive_dependencies_are_ready_when_every_provider_is_published() {
    let data_root = TestDataRoot::new();
    let base = command(".base", Vec::new(), vec![provision("base", CONTRACT)]);
    let provider = command(
        ".provider",
        vec![requirement(".base", "base", CONTRACT)],
        vec![provision("fixture", CONTRACT)],
    );
    let consumer = command(
        ".consumer",
        vec![requirement(".provider", "fixture", CONTRACT)],
        Vec::new(),
    );
    publish(&data_root.path, &base);
    publish(&data_root.path, &provider);
    let snapshot = snapshot(vec![base, provider, consumer]);

    let document = inspect(&data_root.path, "swawkit", &snapshot, ".consumer").unwrap();

    assert!(document.ready);
    assert!(document.dependencies[0].ready);
    assert!(document.dependencies[0].dependencies[0].ready);
    assert!(assert_dependencies_ready(&data_root.path, "swawkit", &snapshot, ".consumer").is_ok());
}

#[test]
fn inspection_and_execution_gate_share_provider_state_failure() {
    let snapshot = snapshot(vec![
        command(
            ".provider",
            Vec::new(),
            vec![provision("fixture", CONTRACT)],
        ),
        command(
            ".consumer",
            vec![requirement(".provider", "fixture", CONTRACT)],
            Vec::new(),
        ),
    ]);
    let data_root = TestDataRoot::new();

    let document = inspect(&data_root.path, "swawkit", &snapshot, ".consumer").unwrap();
    let error =
        assert_dependencies_ready(&data_root.path, "swawkit", &snapshot, ".consumer").unwrap_err();
    let value = serde_json::to_value(&document).unwrap();
    let dependency = &value["dependencies"][0];

    assert!(!document.ready);
    assert_eq!(document.dependencies[0].status, "state-missing");
    assert!(error.contains("command dependencies are not ready"));
    assert!(error.contains("state-missing"));
    assert_eq!(
        document.dependencies[0].message.as_deref(),
        Some("run 'swawkit .provider'")
    );
    assert_exact_fields(
        dependency,
        &[
            "provider",
            "export",
            "contract",
            "ready",
            "status",
            "message",
            "dependencies",
        ],
    );
}

#[test]
fn provider_path_ancestors_fail_closed_for_inspection_and_execution() {
    let data_root = TestDataRoot::new();
    fs::write(data_root.path.join("modules"), b"not a directory").unwrap();
    let snapshot = snapshot(vec![
        command(
            ".provider",
            Vec::new(),
            vec![provision("fixture", CONTRACT)],
        ),
        command(
            ".consumer",
            vec![requirement(".provider", "fixture", CONTRACT)],
            Vec::new(),
        ),
    ]);

    let document = inspect(&data_root.path, "swawkit", &snapshot, ".consumer").unwrap();
    let error =
        assert_dependencies_ready(&data_root.path, "swawkit", &snapshot, ".consumer").unwrap_err();

    assert!(!document.ready);
    assert_eq!(document.dependencies[0].status, "provider-path-invalid");
    assert!(error.contains("provider-path-invalid"));
    assert!(
        document.dependencies[0]
            .message
            .as_deref()
            .is_some_and(|message| message.contains("not a regular directory"))
    );
}

#[test]
fn provider_path_reparse_ancestor_is_never_followed() {
    let data_root = TestDataRoot::new();
    let external = data_root.path.with_extension("external");
    fs::create_dir(&external).unwrap();
    let modules = data_root.path.join("modules");
    if let Err(error) = std::os::windows::fs::symlink_dir(&external, &modules) {
        eprintln!("skipping provider reparse test: {error}");
        let _ = fs::remove_dir_all(external);
        return;
    }
    let snapshot = snapshot(vec![
        command(
            ".provider",
            Vec::new(),
            vec![provision("fixture", CONTRACT)],
        ),
        command(
            ".consumer",
            vec![requirement(".provider", "fixture", CONTRACT)],
            Vec::new(),
        ),
    ]);

    let document = inspect(&data_root.path, "swawkit", &snapshot, ".consumer").unwrap();

    assert!(!document.ready);
    assert_eq!(document.dependencies[0].status, "provider-path-invalid");
    fs::remove_dir(modules).unwrap();
    fs::remove_dir_all(external).unwrap();
}

#[test]
fn missing_provider_and_undeclared_contract_are_explicit_failures() {
    let cases = [
        (
            snapshot(vec![command(
                ".consumer",
                vec![requirement(".missing", "fixture", CONTRACT)],
                Vec::new(),
            )]),
            "provider-missing",
        ),
        (
            snapshot(vec![
                command(".provider", Vec::new(), vec![provision("other", CONTRACT)]),
                command(
                    ".consumer",
                    vec![requirement(".provider", "fixture", CONTRACT)],
                    Vec::new(),
                ),
            ]),
            "contract-not-declared",
        ),
    ];

    for (snapshot, expected_status) in cases {
        let document = inspect(Path::new("unused"), "swawkit", &snapshot, ".consumer").unwrap();
        let error =
            assert_dependencies_ready(Path::new("unused"), "swawkit", &snapshot, ".consumer")
                .unwrap_err();

        assert!(!document.ready);
        assert_eq!(document.dependencies[0].status, expected_status);
        assert!(error.contains(expected_status));
    }
}

#[test]
fn recursive_cycle_is_reported_and_blocks_readiness() {
    let data_root = TestDataRoot::new();
    let a = command(
        ".a",
        vec![requirement(".b", "b", CONTRACT)],
        vec![provision("a", CONTRACT)],
    );
    let b = command(
        ".b",
        vec![requirement(".a", "a", CONTRACT)],
        vec![provision("b", CONTRACT)],
    );
    let consumer = command(
        ".consumer",
        vec![requirement(".a", "a", CONTRACT)],
        Vec::new(),
    );
    publish(&data_root.path, &a);
    publish(&data_root.path, &b);
    let snapshot = snapshot(vec![a, b, consumer]);

    let document = inspect(&data_root.path, "swawkit", &snapshot, ".consumer").unwrap();
    let cycle = &document.dependencies[0].dependencies[0].dependencies[0];
    let error =
        assert_dependencies_ready(&data_root.path, "swawkit", &snapshot, ".consumer").unwrap_err();

    assert!(!document.ready);
    assert!(!cycle.ready);
    assert_eq!(cycle.status, "cycle");
    assert_eq!(
        cycle.message.as_deref(),
        Some("module dependency cycle detected")
    );
    assert!(error.contains("cycle"));
}

#[test]
fn dependency_depth_accepts_32_and_rejects_33_without_a_partial_document() {
    let boundary = dependency_chain(MAX_DEPENDENCY_DEPTH + 1);
    let document = inspect(Path::new("unused"), "swawkit", &boundary, ".consumer").unwrap();

    assert_eq!(
        dependency_chain_length(&document.dependencies[0]),
        MAX_DEPENDENCY_DEPTH + 1
    );

    let over_limit = dependency_chain(MAX_DEPENDENCY_DEPTH + 2);
    let inspect_error =
        inspect(Path::new("unused"), "swawkit", &over_limit, ".consumer").unwrap_err();
    let gate_error =
        assert_dependencies_ready(Path::new("unused"), "swawkit", &over_limit, ".consumer")
            .unwrap_err();

    assert_eq!(inspect_error, gate_error);
    assert!(
        inspect_error.contains("command dependency depth exceeds maximum 32"),
        "{inspect_error}"
    );
}

#[test]
fn dependency_width_accepts_512_and_rejects_513_without_a_partial_document() {
    let boundary = dependency_width(MAX_DEPENDENCY_ITEMS);
    let document = inspect(Path::new("unused"), "swawkit", &boundary, ".consumer").unwrap();

    assert_eq!(document.dependencies.len(), MAX_DEPENDENCY_ITEMS);

    let over_limit = dependency_width(MAX_DEPENDENCY_ITEMS + 1);
    let inspect_error =
        inspect(Path::new("unused"), "swawkit", &over_limit, ".consumer").unwrap_err();
    let gate_error =
        assert_dependencies_ready(Path::new("unused"), "swawkit", &over_limit, ".consumer")
            .unwrap_err();

    assert_eq!(inspect_error, gate_error);
    assert!(
        inspect_error.contains("command dependency graph exceeds maximum 512 items"),
        "{inspect_error}"
    );
}

fn dependency_chain(length: usize) -> CatalogSnapshot {
    let mut commands = (0..length)
        .map(|index| {
            let address = format!(".provider-{index}");
            let requires = (index + 1 < length)
                .then(|| requirement(&format!(".provider-{}", index + 1), "fixture", CONTRACT))
                .into_iter()
                .collect();
            command(&address, requires, vec![provision("fixture", CONTRACT)])
        })
        .collect::<Vec<_>>();
    commands.push(command(
        ".consumer",
        vec![requirement(".provider-0", "fixture", CONTRACT)],
        Vec::new(),
    ));
    snapshot(commands)
}

fn dependency_width(width: usize) -> CatalogSnapshot {
    snapshot(vec![command(
        ".consumer",
        (0..width)
            .map(|index| requirement(&format!(".missing-{index}"), "fixture", CONTRACT))
            .collect(),
        Vec::new(),
    )])
}

fn dependency_chain_length(dependency: &DependencyCheck) -> usize {
    1 + dependency
        .dependencies
        .first()
        .map(dependency_chain_length)
        .unwrap_or_default()
}

fn snapshot(commands: Vec<CommandNode>) -> CatalogSnapshot {
    CatalogSnapshot {
        protocol: CATALOG_PROTOCOL,
        entry_name: "swawkit".to_owned(),
        language: "en",
        commands,
    }
}

fn command(
    address: &str,
    requires: Vec<ModuleRequirement>,
    provides: Vec<ModuleProvision>,
) -> CommandNode {
    CommandNode {
        address: address.to_owned(),
        space: CommandSpace::System,
        namespace: None,
        path: vec![address.trim_start_matches('.').to_owned()],
        parent: None,
        alias_of: None,
        runnable: true,
        entry: Some("run.exe".to_owned()),
        adapter: Some("exe".to_owned()),
        handler: None,
        product: None,
        module: Some(CommandModuleContract {
            schema: MODULE_CONTRACT_PROTOCOL.to_owned(),
            execution: None,
            requires,
            provides,
            facets: Vec::new(),
            subject_kinds: Vec::new(),
        }),
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

fn requirement(provider: &str, export: &str, contract: &str) -> ModuleRequirement {
    ModuleRequirement {
        provider: provider.to_owned(),
        export: export.to_owned(),
        contract: contract.to_owned(),
    }
}

fn provision(id: &str, contract: &str) -> ModuleProvision {
    ModuleProvision {
        id: id.to_owned(),
        contract: contract.to_owned(),
    }
}

fn publish(data_root: &Path, provider: &CommandNode) {
    let module = data_root
        .join("modules/system")
        .join(provider.address.trim_start_matches('.'));
    fs::create_dir_all(module.join("export")).unwrap();
    let exports = provider
        .module
        .as_ref()
        .unwrap()
        .provides
        .iter()
        .map(|provision| {
            json!({
                "id": provision.id,
                "contract": provision.contract,
            })
        })
        .collect::<Vec<_>>();
    let state = json!({
        "schema": "swawkit.command-provider-state/v2",
        "status": "ready",
        "inputRevision": format!("sha256-{}", "a".repeat(64)),
        "token": "b".repeat(32),
        "exports": exports,
    });
    fs::write(
        module.join("_state.json"),
        serde_json::to_vec(&state).unwrap(),
    )
    .unwrap();
}

fn assert_exact_fields(value: &Value, expected: &[&str]) {
    let mut actual = value
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect::<Vec<_>>();
    let mut expected = expected.to_vec();
    actual.sort_unstable();
    expected.sort_unstable();
    assert_eq!(actual, expected);
}

struct TestDataRoot {
    path: PathBuf,
}

impl TestDataRoot {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "swawkit-command-check-{}-{}",
            std::process::id(),
            NEXT_ROOT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&path).unwrap();
        Self { path }
    }
}

impl Drop for TestDataRoot {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}
