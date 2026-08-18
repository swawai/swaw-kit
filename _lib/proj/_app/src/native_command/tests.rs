use std::env;
use std::fs;
use std::sync::atomic::{AtomicU64, Ordering};

use super::storage::hex_sha256;
use super::*;
use crate::catalog::{CATALOG_PROTOCOL, CatalogSnapshot, CommandNode, CommandSpace};

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);
const FIXTURE_OWNER: &str = "swaw/fixture";

struct Fixture {
    root: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let root = Path::new(env!("CARGO_MANIFEST_DIR"))
            .ancestors()
            .nth(3)
            .expect("workspace root")
            .join("data/proj_cache/tests/native-command")
            .join(format!("{}-{sequence}", std::process::id()));
        fs::create_dir_all(&root).expect("create fixture root");
        Self { root }
    }

    fn publish(&self, bytes: &[u8]) -> PathBuf {
        let source = fixture_source_contract(&[]);
        let document = release::release_document(FIXTURE_OWNER, source, bytes).unwrap();
        let publication = publish_executable(&self.root, bytes, &document).unwrap();
        self.root
            .join("_native/export/command/releases")
            .join(publication.release_id)
            .join("run.exe")
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.root).expect("remove fixture");
    }
}

#[test]
fn resolves_the_content_addressed_current_executable() {
    let fixture = Fixture::new();
    let expected = fixture.publish(b"native command fixture");

    assert_eq!(
        resolve_executable(&fixture.root, FIXTURE_OWNER, &fixture_source_contract(&[])).unwrap(),
        expected
    );
}

#[test]
fn reports_an_uninstantiated_module_without_attempting_a_build() {
    let fixture = Fixture::new();

    let error = resolve_executable(&fixture.root, FIXTURE_OWNER, &fixture_source_contract(&[]))
        .unwrap_err()
        .to_string();

    assert!(error.contains("has not been instantiated"), "{error}");
    assert!(error.contains("export"), "{error}");
}

#[test]
fn rejects_an_executable_that_does_not_match_the_selected_release() {
    let fixture = Fixture::new();
    let executable = fixture.publish(b"original");
    fs::write(executable, b"tampered").expect("tamper executable");

    let error = resolve_executable(&fixture.root, FIXTURE_OWNER, &fixture_source_contract(&[]))
        .unwrap_err()
        .to_string();

    assert!(
        error.contains("does not match its release manifest"),
        "{error}"
    );
}

#[test]
fn publication_is_immutable_idempotent_and_switches_only_the_selector() {
    let fixture = Fixture::new();

    let source = fixture_source_contract(&[]);
    let first_document =
        release::release_document(FIXTURE_OWNER, source.clone(), b"first release").unwrap();
    let first = publish_executable(&fixture.root, b"first release", &first_document).unwrap();
    assert!(first.changed);
    let repeated = publish_executable(&fixture.root, b"first release", &first_document).unwrap();
    assert!(!repeated.changed);
    assert_eq!(repeated.release_id, first.release_id);

    let second_document =
        release::release_document(FIXTURE_OWNER, source.clone(), b"second release").unwrap();
    let second = publish_executable(&fixture.root, b"second release", &second_document).unwrap();
    assert!(second.changed);
    assert_ne!(second.release_id, first.release_id);
    assert!(
        fixture
            .root
            .join("_native/export/command/releases")
            .join(&first.release_id)
            .join("run.exe")
            .is_file()
    );
    assert!(
        fixture
            .root
            .join("_native/export/command/releases")
            .join(&first.release_id)
            .join(release::RELEASE_FILE)
            .is_file()
    );
    assert_eq!(
        resolve_executable(&fixture.root, FIXTURE_OWNER, &source).unwrap(),
        fixture
            .root
            .join("_native/export/command/releases")
            .join(second.release_id)
            .join("run.exe")
    );
}

#[test]
fn source_contract_drift_blocks_an_old_selected_release() {
    let fixture = Fixture::new();
    fixture.publish(b"native command fixture");
    let current_source = fixture_source_contract(&["swaw/fixture/new-port"]);

    let error = resolve_executable(&fixture.root, FIXTURE_OWNER, &current_source)
        .unwrap_err()
        .to_string();

    assert!(error.contains("source contract does not match"), "{error}");
}

#[test]
fn instantiates_one_independent_cargo_project_and_runs_its_published_executable() {
    let fixture = Fixture::new();
    let command_directory = fixture.root.join("modules/fixture");
    fs::create_dir_all(command_directory.join("src")).unwrap();
    fs::write(
        command_directory.join("Cargo.toml"),
        "[package]\nname = \"native-fixture\"\nversion = \"0.1.0\"\nedition = \"2024\"\n\n[[bin]]\nname = \"run\"\npath = \"src/main.rs\"\n",
    )
    .unwrap();
    fs::write(
        command_directory.join("Cargo.lock"),
        "# This file is automatically @generated by Cargo.\n# It is not intended for manual editing.\nversion = 4\n\n[[package]]\nname = \"native-fixture\"\nversion = \"0.1.0\"\n",
    )
    .unwrap();
    fs::write(
        command_directory.join("src/main.rs"),
        native_fixture_source(FIXTURE_OWNER, &[], "independent native fixture"),
    )
    .unwrap();
    fs::write(
        command_directory.join("swawkit.module.json"),
        r#"{"schema":"swawkit.command-module/v8","execution":{"type":"native"}}"#,
    )
    .unwrap();
    let command = CommandNode {
        address: "swaw/fixture".to_owned(),
        space: CommandSpace::Module,
        namespace: Some("swaw".to_owned()),
        path: vec!["fixture".to_owned()],
        parent: Some("swaw".to_owned()),
        alias_of: None,
        runnable: true,
        entry: Some("swawkit.module.json".to_owned()),
        adapter: Some("native".to_owned()),
        handler: None,
        module: None,
        help: None,
        subject_kinds: Vec::new(),
        facets: Vec::new(),
        view: None,
        diagnostic: None,
        help_diagnostic: None,
        directory: command_directory,
        native_owner: Some("swaw/fixture".to_owned()),
    };
    let data_root = fixture.root.join("data");
    let catalog = CatalogSnapshot {
        protocol: CATALOG_PROTOCOL,
        entry_name: "fixture".to_owned(),
        language: "en",
        commands: vec![command.clone()],
    };
    let cargo = env::var_os("CARGO").map(PathBuf::from).unwrap_or_else(|| {
        PathBuf::from(env::var_os("CARGO_HOME").expect("Cargo executable or home"))
            .join("bin/cargo.exe")
    });

    let publication = instantiate_with_cargo(&data_root, &catalog, &command, &cargo).unwrap();
    assert!(publication.changed);
    let source = release::source_contract(&catalog, &command).unwrap();
    let executable = resolve_executable(
        &data_root.join("modules/swaw/fixture"),
        FIXTURE_OWNER,
        &source,
    )
    .unwrap();
    let output = Command::new(executable).output().unwrap();

    assert!(output.status.success());
    assert_eq!(output.stdout, b"independent native fixture\n");
}

#[test]
fn instantiating_a_delegated_port_builds_only_its_native_owner() {
    let fixture = Fixture::new();
    let system_root = fixture.root.join("system");
    let swaw_root = fixture.root.join("modules");
    let project_root = fixture.root.join("project");
    let owner_directory = swaw_root.join("domain");
    let port_directory = owner_directory.join("show");
    fs::create_dir_all(&system_root).unwrap();
    fs::create_dir_all(&project_root).unwrap();
    let source = native_fixture_source("swaw/domain", &["swaw/domain/show"], "one domain engine");
    cargo_fixture(&owner_directory, "native-domain", &source);
    fs::create_dir_all(&port_directory).unwrap();
    fs::write(
        port_directory.join("swawkit.module.json"),
        r#"{"schema":"swawkit.command-module/v8","execution":{"type":"delegate","owner":{"type":"command","space":"module","namespace":"swaw","address":"swaw/domain"}}}"#,
    )
    .unwrap();
    let catalog =
        CatalogSnapshot::discover_roots(&system_root, &swaw_root, &project_root, "fixture")
            .unwrap();
    let port = catalog
        .commands
        .iter()
        .find(|command| command.address == "swaw/domain/show")
        .unwrap();
    let data_root = fixture.root.join("data");
    let owner_data_root = data_root.join("modules/swaw/domain");
    let cargo = env::var_os("CARGO")
        .map(PathBuf::from)
        .expect("Cargo test process publishes CARGO");

    let publication = instantiate_with_cargo(&data_root, &catalog, port, &cargo).unwrap();

    assert!(publication.changed);
    assert!(!data_root.join("modules/swaw/domain/show/_native").exists());
    let owner = catalog
        .commands
        .iter()
        .find(|command| command.address == "swaw/domain")
        .unwrap();
    let source = release::source_contract(&catalog, owner).unwrap();
    let output =
        Command::new(resolve_executable(&owner_data_root, "swaw/domain", &source).unwrap())
            .output()
            .unwrap();
    assert!(output.status.success());
    assert_eq!(output.stdout, b"one domain engine\n");
}

#[test]
fn instantiation_rejects_a_candidate_missing_a_declared_port() {
    let fixture = Fixture::new();
    let system_root = fixture.root.join("system");
    let swaw_root = fixture.root.join("modules");
    let project_root = fixture.root.join("project");
    let owner_directory = swaw_root.join("broken");
    let port_directory = owner_directory.join("show");
    fs::create_dir_all(&system_root).unwrap();
    fs::create_dir_all(&project_root).unwrap();
    let source = native_fixture_source("swaw/broken", &[], "broken domain engine");
    cargo_fixture(&owner_directory, "native-broken", &source);
    fs::create_dir_all(&port_directory).unwrap();
    fs::write(
        port_directory.join("swawkit.module.json"),
        r#"{"schema":"swawkit.command-module/v8","execution":{"type":"delegate","owner":{"type":"command","space":"module","namespace":"swaw","address":"swaw/broken"}}}"#,
    )
    .unwrap();
    let catalog =
        CatalogSnapshot::discover_roots(&system_root, &swaw_root, &project_root, "fixture")
            .unwrap();
    let owner = catalog
        .commands
        .iter()
        .find(|command| command.address == "swaw/broken")
        .unwrap();
    let data_root = fixture.root.join("data");
    let cargo = env::var_os("CARGO").map(PathBuf::from).unwrap();

    let error = instantiate_with_cargo(&data_root, &catalog, owner, &cargo).unwrap_err();

    assert!(error.contains("ports do not match"), "{error}");
    assert!(
        !data_root
            .join("modules/swaw/broken/_native/export/command/current")
            .exists()
    );
}

#[test]
fn selects_the_real_cargo_beside_the_validated_managed_rustc() {
    let fixture = Fixture::new();
    let toolchain = fixture.root.join("managed/toolchain/bin");
    fs::create_dir_all(&toolchain).unwrap();
    let rustc = toolchain.join("rustc.exe");
    let cargo = toolchain.join("cargo.exe");
    fs::write(&rustc, b"rustc").unwrap();
    fs::write(&cargo, b"cargo").unwrap();

    assert_eq!(managed_toolchain_cargo(&rustc).unwrap(), cargo);
    assert!(
        managed_toolchain_cargo(&toolchain.join("compiler.exe"))
            .unwrap_err()
            .contains("rustc.exe")
    );
}

fn cargo_fixture(directory: &Path, package: &str, source: &str) {
    fs::create_dir_all(directory.join("src")).unwrap();
    fs::write(
        directory.join("swawkit.module.json"),
        r#"{"schema":"swawkit.command-module/v8","execution":{"type":"native"}}"#,
    )
    .unwrap();
    fs::write(
        directory.join("Cargo.toml"),
        format!(
            "[package]\nname = \"{package}\"\nversion = \"0.1.0\"\nedition = \"2024\"\n\n[[bin]]\nname = \"run\"\npath = \"src/main.rs\"\n"
        ),
    )
    .unwrap();
    fs::write(
        directory.join("Cargo.lock"),
        format!(
            "# This file is automatically @generated by Cargo.\n# It is not intended for manual editing.\nversion = 4\n\n[[package]]\nname = \"{package}\"\nversion = \"0.1.0\"\n"
        ),
    )
    .unwrap();
    fs::write(directory.join("src/main.rs"), source).unwrap();
}

fn fixture_source_contract(commands: &[&str]) -> release::SourceContract {
    let manifests = vec![release::SourceManifest {
        address: FIXTURE_OWNER.to_owned(),
        sha256: "a".repeat(64),
    }];
    let identity = serde_json::to_vec(&manifests).unwrap();
    release::SourceContract {
        sha256: hex_sha256(&identity),
        commands: commands
            .iter()
            .map(|command| (*command).to_owned())
            .collect(),
        manifests,
    }
}

fn native_fixture_source(owner: &str, commands: &[&str], output: &str) -> String {
    let description = serde_json::json!({
        "schema": release::DESCRIPTION_PROTOCOL,
        "owner": owner,
        "commands": commands,
    })
    .to_string();
    format!(
        "fn main() {{ if std::env::args().nth(1).as_deref() == Some(\"{}\") {{ println!(\"{{}}\", {description:?}); return; }} println!(\"{{}}\", {output:?}); }}\n",
        release::DESCRIPTION_ARGUMENT,
    )
}
