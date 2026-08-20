use super::*;
use crate::filesystem::unique_token;

const VALID_FULL: &[u8] = include_bytes!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../_protocol/tests/fixtures/command-module/valid-full.json"
));
const INVALID_FACET: &[u8] = include_bytes!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../_protocol/tests/fixtures/command-module/invalid-facet.json"
));
const INVALID_SUBJECT_KIND: &[u8] = include_bytes!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../_protocol/tests/fixtures/command-module/invalid-subject-kind.json"
));

struct Fixture(PathBuf);

impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("swawkit-manifest-{}", unique_token()));
        fs::create_dir(&root).unwrap();
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
fn nested_native_owner_is_not_part_of_parent_contract() {
    let fixture = Fixture::new();
    let owner = fixture.0.join("context");
    let delegate = owner.join("add");
    let nested = owner.join("child");
    let nested_delegate = nested.join("show");
    let hidden = owner.join("source/hidden");
    fs::create_dir_all(&delegate).unwrap();
    fs::create_dir_all(&nested_delegate).unwrap();
    fs::create_dir_all(&hidden).unwrap();
    fs::write(
        owner.join(MODULE_MANIFEST),
        r#"{"schema":"swawkit.command-module/v12","execution":{"type":"native"}}"#,
    )
    .unwrap();
    write_delegate(&delegate, "swaw/context");
    fs::write(
        nested.join(MODULE_MANIFEST),
        r#"{"schema":"swawkit.command-module/v12","execution":{"type":"native"}}"#,
    )
    .unwrap();
    write_delegate(&nested_delegate, "swaw/context/child");
    write_delegate(&hidden, "swaw/context");

    let domain = discover_module(&fixture.0, "swaw/context").unwrap();
    assert_eq!(domain.commands(), ["swaw/context/add"]);
    assert_eq!(domain.nested_owner_directories, [nested]);
}

#[test]
fn system_native_owner_and_delegate_form_one_contract() {
    let fixture = Fixture::new();
    let system = fixture.0.join("system");
    let owner = system.join("context");
    let delegate = owner.join("add");
    fs::create_dir_all(&delegate).unwrap();
    fs::write(
        owner.join(MODULE_MANIFEST),
        r#"{"schema":"swawkit.command-module/v12","execution":{"type":"native"}}"#,
    )
    .unwrap();
    write_system_delegate(&delegate, ".context");

    let domain = discover_native_domain(&system, &BTreeMap::new(), ".context/add").unwrap();
    assert_eq!(domain.requested_address, ".context/add");
    assert_eq!(domain.owner_address, ".context");
    assert_eq!(domain.owner_identity.space(), CommandSpace::System);
    assert_eq!(domain.commands(), [".context/add"]);
}

#[test]
fn delegates_cannot_cross_command_spaces() {
    {
        let fixture = Fixture::new();
        let system = fixture.0.join("system");
        let delegate = system.join("context/add");
        fs::create_dir_all(&delegate).unwrap();
        fs::write(
            delegate.join(MODULE_MANIFEST),
            r#"{"schema":"swawkit.command-module/v12","execution":{"type":"delegate","owner":{"type":"command","space":"module","namespace":"swaw","address":"swaw/context"}}}"#,
        )
        .unwrap();
        let error = discover_native_domain(
            &system,
            &BTreeMap::from([("swaw".to_owned(), fixture.0.join("modules"))]),
            ".context/add",
        )
        .err()
        .expect("System delegate cannot target a Module owner");
        assert!(error.contains("same command space"), "{error}");
    }

    let fixture = Fixture::new();
    let modules = fixture.0.join("modules");
    let delegate = modules.join("context/add");
    fs::create_dir_all(&delegate).unwrap();
    fs::write(
        delegate.join(MODULE_MANIFEST),
        r#"{"schema":"swawkit.command-module/v12","execution":{"type":"delegate","owner":{"type":"command","space":"system","address":".context"}}}"#,
    )
    .unwrap();
    let error = discover_native_domain(
        &fixture.0.join("system"),
        &BTreeMap::from([("swaw".to_owned(), modules)]),
        "swaw/context/add",
    )
    .err()
    .expect("Module delegate cannot target a System owner");
    assert!(error.contains("same command space"), "{error}");
}

#[test]
fn shared_full_manifest_enters_the_native_contract() {
    let fixture = Fixture::new();
    let owner = fixture.0.join("context");
    fs::create_dir(&owner).unwrap();
    fs::write(owner.join(MODULE_MANIFEST), VALID_FULL).unwrap();

    let domain = discover_module(&fixture.0, "swaw/context")
        .expect("shared v10 fixture must be publishable");

    let owner = domain
        .execution_contract
        .commands()
        .iter()
        .find(|command| command.address == "swaw/context")
        .expect("native owner contract member");
    assert_eq!(owner.requires.len(), 1);
    assert_eq!(owner.provides.len(), 1);
}

#[test]
fn shared_invalid_ui_declarations_never_enter_a_publication_contract() {
    for manifest in [INVALID_FACET, INVALID_SUBJECT_KIND] {
        let fixture = Fixture::new();
        let owner = fixture.0.join("context");
        fs::create_dir(&owner).unwrap();
        fs::write(owner.join(MODULE_MANIFEST), manifest).unwrap();

        let error = discover_module(&fixture.0, "swaw/context")
            .err()
            .expect("invalid UI declarations must fail before publication");
        assert!(error.contains("invalid command manifest"), "{error}");
    }
}

#[test]
fn noncanonical_directory_or_manifest_names_are_rejected() {
    {
        let fixture = Fixture::new();
        let owner = fixture.0.join("Context");
        fs::create_dir(&owner).unwrap();
        fs::write(
            owner.join(MODULE_MANIFEST),
            r#"{"schema":"swawkit.command-module/v12","execution":{"type":"native"}}"#,
        )
        .unwrap();
        let error = discover_module(&fixture.0, "swaw/context").err().unwrap();
        assert!(error.contains("non-canonical command directory"), "{error}");
    }

    let fixture = Fixture::new();
    let owner = fixture.0.join("context");
    fs::create_dir(&owner).unwrap();
    fs::write(
        owner.join("Swawkit.Module.Json"),
        r#"{"schema":"swawkit.command-module/v12","execution":{"type":"native"}}"#,
    )
    .unwrap();
    let error = discover_module(&fixture.0, "swaw/context").err().unwrap();
    assert!(error.contains("non-canonical command manifest"), "{error}");

    let fixture = Fixture::new();
    let system = fixture.0.join("system");
    let owner = system.join("Context");
    fs::create_dir_all(&owner).unwrap();
    fs::write(
        owner.join(MODULE_MANIFEST),
        r#"{"schema":"swawkit.command-module/v12","execution":{"type":"native"}}"#,
    )
    .unwrap();
    let error = discover_native_domain(&system, &BTreeMap::new(), ".context")
        .err()
        .expect("System directory casing must be canonical");
    assert!(error.contains("non-canonical command directory"), "{error}");
}

#[test]
fn native_execution_with_local_run_ts_never_enters_a_contract() {
    let fixture = Fixture::new();
    let owner = fixture.0.join("context");
    fs::create_dir(&owner).unwrap();
    fs::write(
        owner.join(MODULE_MANIFEST),
        r#"{"schema":"swawkit.command-module/v12","execution":{"type":"native"}}"#,
    )
    .unwrap();
    fs::write(owner.join("run.ts"), "").unwrap();

    let error = discover_module(&fixture.0, "swaw/context")
        .err()
        .expect("native execution and run.ts must conflict");
    assert!(error.contains("both a local run.* entry"), "{error}");
}

#[test]
fn delegated_execution_with_local_run_ts_never_enters_the_owner_contract() {
    let fixture = Fixture::new();
    let owner = fixture.0.join("context");
    let delegate = owner.join("add");
    fs::create_dir_all(&delegate).unwrap();
    fs::write(
        owner.join(MODULE_MANIFEST),
        r#"{"schema":"swawkit.command-module/v12","execution":{"type":"native"}}"#,
    )
    .unwrap();
    write_delegate(&delegate, "swaw/context");
    fs::write(delegate.join("run.ts"), "").unwrap();

    let error = discover_module(&fixture.0, "swaw/context")
        .err()
        .expect("delegated execution and run.ts must conflict");
    assert!(error.contains("both a local run.* entry"), "{error}");
}

#[test]
fn malformed_local_entries_never_enter_a_native_contract() {
    for (entries, expected) in [
        (&["RUN.TS"][..], "non-canonical entry name"),
        (&["run.ts", "run.py"][..], "multiple run entries"),
        (&["run.delegate"][..], "obsolete command entry"),
    ] {
        let fixture = Fixture::new();
        let owner = fixture.0.join("context");
        fs::create_dir(&owner).unwrap();
        fs::write(
            owner.join(MODULE_MANIFEST),
            r#"{"schema":"swawkit.command-module/v12","execution":{"type":"native"}}"#,
        )
        .unwrap();
        for entry in entries {
            fs::write(owner.join(entry), "").unwrap();
        }

        let error = discover_module(&fixture.0, "swaw/context")
            .err()
            .expect("invalid local entry declaration must fail discovery");
        assert!(error.contains(expected), "{error}");
    }
}

fn write_delegate(directory: &Path, owner: &str) {
    fs::write(
        directory.join(MODULE_MANIFEST),
        format!(
            r#"{{"schema":"swawkit.command-module/v12","execution":{{"type":"delegate","owner":{{"type":"command","space":"module","namespace":"swaw","address":"{owner}"}}}}}}"#
        ),
    )
    .unwrap();
}

fn write_system_delegate(directory: &Path, owner: &str) {
    fs::write(
        directory.join(MODULE_MANIFEST),
        format!(
            r#"{{"schema":"swawkit.command-module/v12","execution":{{"type":"delegate","owner":{{"type":"command","space":"system","address":"{owner}"}}}}}}"#
        ),
    )
    .unwrap();
}
