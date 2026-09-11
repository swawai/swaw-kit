use super::*;
use crate::filesystem::unique_token;
use swawkit_proj_protocol::serde_json;

struct Fixture(PathBuf);

impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("swawkit-manifest-{}", unique_token()));
        fs::create_dir(&root).unwrap();
        fs::create_dir(root.join("system")).unwrap();
        Self(root)
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn discover_module(root: &Path, requested: &str) -> Result<NativeDomain, String> {
    discover_native_domain(
        &root.join("system"),
        &BTreeMap::from([("swaw".to_owned(), root.to_path_buf())]),
        requested,
    )
}

#[test]
fn native_owner_and_delegate_form_one_contract() {
    let fixture = Fixture::new();
    let owner = fixture.0.join("context");
    let delegate = child(&owner, "add");
    write_execution(&owner, serde_json::json!({ "type": "native" }));
    write_execution(
        &delegate,
        serde_json::json!({
            "type": "native-delegate",
            "owner": "$/modules::swaw/subcommands::context/execute"
        }),
    );

    let domain = discover_module(&fixture.0, "swaw/context/add").unwrap();
    assert_eq!(domain.owner_address, "swaw/context");
    assert_eq!(domain.commands(), ["swaw/context/add"]);
}

#[test]
fn nested_native_owner_is_pruned_from_the_parent_domain() {
    let fixture = Fixture::new();
    let owner = fixture.0.join("context");
    let delegate = child(&owner, "add");
    let nested = child(&owner, "child");
    let nested_delegate = child(&nested, "show");
    write_execution(&owner, serde_json::json!({ "type": "native" }));
    write_execution(
        &delegate,
        serde_json::json!({
            "type": "native-delegate",
            "owner": "$/modules::swaw/subcommands::context/execute"
        }),
    );
    write_execution(&nested, serde_json::json!({ "type": "native" }));
    write_execution(
        &nested_delegate,
        serde_json::json!({
            "type": "native-delegate",
            "owner": "$/modules::swaw/subcommands::context/subcommands::child/execute"
        }),
    );

    let domain = discover_module(&fixture.0, "swaw/context").unwrap();
    assert_eq!(domain.commands(), ["swaw/context/add"]);
    assert_eq!(domain.nested_owner_directories, [nested]);
}

#[test]
fn delegate_owner_must_be_an_ancestor_in_the_same_command_space() {
    let fixture = Fixture::new();
    let owner = fixture.0.join("context");
    let delegate = child(&owner, "add");
    write_execution(&owner, serde_json::json!({ "type": "native" }));
    write_execution(
        &delegate,
        serde_json::json!({
            "type": "native-delegate",
            "owner": "$/system::context/execute"
        }),
    );

    let error = discover_module(&fixture.0, "swaw/context/add")
        .err()
        .expect("cross-space delegate must fail");
    assert!(error.contains("true ancestor"), "{error}");
}

#[test]
fn capabilities_are_compiled_into_the_execution_contract() {
    let fixture = Fixture::new();
    let provider = fixture.0.join("provider");
    let owner = fixture.0.join("context");
    write_execution(&provider, serde_json::json!({ "type": "native" }));
    write_execution(&owner, serde_json::json!({ "type": "native" }));
    fs::write(
        provider.join(EXPORTS_FILE),
        r#"{"schema":"swawkit.resource-exports/v1","exports":[{"id":"fixture"}]}"#,
    )
    .unwrap();
    fs::write(
        owner.join("execute").join(REQUIREMENTS_FILE),
        r#"{"schema":"swawkit.facet-requirements/v1","requirements":[{"provider":"$/modules::swaw/subcommands::provider","export":"fixture"}]}"#,
    )
    .unwrap();

    let domain = discover_module(&fixture.0, "swaw/context").unwrap();
    let command = &domain.execution_contract.commands()[0];
    assert_eq!(command.requires[0].provider, "swaw/provider");
    assert_eq!(command.requires[0].export, "fixture");
}

#[test]
fn declared_execution_cannot_coexist_with_a_local_entry() {
    let fixture = Fixture::new();
    let owner = fixture.0.join("context");
    write_execution(&owner, serde_json::json!({ "type": "native" }));
    fs::write(owner.join("execute/run.ts"), "").unwrap();

    let error = discover_module(&fixture.0, "swaw/context")
        .err()
        .expect("mixed execution sources must fail");
    assert!(error.contains("both a local run.* entry"), "{error}");
}

fn child(parent: &Path, selector: &str) -> PathBuf {
    let collection = parent.join(SUBCOMMANDS_FACET);
    fs::create_dir_all(&collection).unwrap();
    fs::write(
        collection.join(FACET_FILE),
        r#"{"schema":"swawkit.facet/v1","kind":"collection"}"#,
    )
    .unwrap();
    collection.join(selector)
}

fn write_execution(directory: &Path, implementation: serde_json::Value) {
    let execute = directory.join(EXECUTE_FACET);
    fs::create_dir_all(&execute).unwrap();
    fs::write(
        directory.join(RESOURCE_FILE),
        r#"{"schema":"swawkit.resource/v1","kind":"command"}"#,
    )
    .unwrap();
    fs::write(
        execute.join(FACET_FILE),
        r#"{"schema":"swawkit.facet/v1","kind":"operation"}"#,
    )
    .unwrap();
    fs::write(
        execute.join(EXECUTION_FILE),
        serde_json::to_vec(&serde_json::json!({
            "schema": "swawkit.facet-execution/v2",
            "implementation": implementation
        }))
        .unwrap(),
    )
    .unwrap();
}
