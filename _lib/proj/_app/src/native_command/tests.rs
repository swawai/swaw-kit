use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use swawkit_proj_protocol::command_release_id;

use super::*;
use crate::catalog::CatalogSnapshot;

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);
const OWNER: &str = "swaw/fixture";

struct Fixture {
    root: PathBuf,
    system_root: PathBuf,
    swaw_root: PathBuf,
    project_root: PathBuf,
    owner_root: PathBuf,
    owner_data_root: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let root = Path::new(env!("CARGO_MANIFEST_DIR"))
            .ancestors()
            .nth(3)
            .expect("workspace root")
            .join("data/proj_cache/tests/native-command-consumer")
            .join(format!("{}-{sequence}", std::process::id()));
        let system_root = root.join("system");
        let swaw_root = root.join("modules");
        let project_root = root.join("project");
        let owner_root = swaw_root.join("fixture");
        let owner_data_root = root.join("data/modules/swaw/fixture");
        for directory in [&system_root, &project_root, &owner_root, &owner_data_root] {
            fs::create_dir_all(directory).expect("create fixture directory");
        }
        fs::write(
            owner_root.join("swawkit.module.json"),
            r#"{"schema":"swawkit.command-module/v9","execution":{"type":"native"}}"#,
        )
        .expect("write owner manifest");
        Self {
            root,
            system_root,
            swaw_root,
            project_root,
            owner_root,
            owner_data_root,
        }
    }

    fn catalog(&self) -> CatalogSnapshot {
        CatalogSnapshot::discover_roots(
            &self.system_root,
            &self.swaw_root,
            &self.project_root,
            "fixture",
        )
        .expect("discover fixture Catalog")
    }

    fn publish(&self, bytes: &[u8]) -> PathBuf {
        let catalog = self.catalog();
        let owner = catalog
            .commands
            .iter()
            .find(|command| command.address == OWNER)
            .expect("fixture owner");
        publish_test_executable(&self.owner_data_root, &catalog, owner, bytes)
            .expect("publish fixture")
    }

    fn resolve(&self) -> CommandResult<PathBuf> {
        let catalog = self.catalog();
        let owner = catalog
            .commands
            .iter()
            .find(|command| command.address == OWNER)
            .expect("fixture owner");
        resolve_test_executable(&self.owner_data_root, &catalog, owner)
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
    assert_eq!(fixture.resolve().unwrap(), expected);
}

#[test]
fn reports_an_uninstantiated_module_without_attempting_a_build() {
    let fixture = Fixture::new();
    let error = fixture.resolve().unwrap_err().to_string();
    assert!(error.contains("has not been instantiated"), "{error}");
    assert!(!fixture.owner_data_root.join("_native").exists());
}

#[test]
fn rejects_an_executable_that_does_not_match_the_selected_release() {
    let fixture = Fixture::new();
    let executable = fixture.publish(b"original");
    fs::write(executable, b"tampered").expect("tamper executable");
    let error = fixture.resolve().unwrap_err().to_string();
    assert!(
        error.contains("does not match its release document"),
        "{error}"
    );
}

#[test]
fn rejects_an_extra_release_member() {
    let fixture = Fixture::new();
    let executable = fixture.publish(b"published executable");
    fs::write(
        executable.parent().unwrap().join("side-load.dll"),
        b"unexpected",
    )
    .expect("write extra release member");
    let error = fixture.resolve().unwrap_err().to_string();
    assert!(error.contains("invalid membership"), "{error}");
}

#[test]
fn rejects_a_noncanonical_selector_without_lf() {
    let fixture = Fixture::new();
    fixture.publish(b"published executable");
    let selector = fixture
        .owner_data_root
        .join("_native/export/command/current");
    let bytes = fs::read(&selector).expect("read selector");
    fs::write(&selector, &bytes[..bytes.len() - 1]).expect("write invalid selector");
    let error = fixture.resolve().unwrap_err().to_string();
    assert!(error.contains("followed by LF"), "{error}");
}

#[test]
fn source_changes_do_not_invalidate_an_explicitly_selected_release() {
    let fixture = Fixture::new();
    let expected = fixture.publish(b"published executable");
    fs::create_dir_all(fixture.owner_root.join("_src")).unwrap();
    fs::write(
        fixture.owner_root.join("_src/main.rs"),
        "fn main() { panic!(\"new unbuilt source\"); }",
    )
    .unwrap();
    assert_eq!(fixture.resolve().unwrap(), expected);
}

#[test]
fn execution_contract_drift_blocks_an_old_selected_release() {
    let fixture = Fixture::new();
    fixture.publish(b"published executable");
    let port = fixture.owner_root.join("show");
    fs::create_dir_all(&port).unwrap();
    fs::write(
        port.join("swawkit.module.json"),
        r#"{"schema":"swawkit.command-module/v9","execution":{"type":"delegate","owner":{"type":"command","space":"module","namespace":"swaw","address":"swaw/fixture"}}}"#,
    )
    .unwrap();
    let error = fixture.resolve().unwrap_err().to_string();
    assert!(
        error.contains("execution contract does not match"),
        "{error}"
    );
}

#[test]
fn old_release_protocol_is_rejected_without_fallback() {
    let fixture = Fixture::new();
    let executable = fixture.publish(b"published executable");
    let release_root = executable.parent().unwrap();
    let document_path = release_root.join("swawkit.release.json");
    let mut value: serde_json::Value =
        serde_json::from_slice(&fs::read(&document_path).unwrap()).unwrap();
    value["schema"] = serde_json::Value::String("swawkit.native-command-release/v1".to_owned());
    let old_document = serde_json::to_vec(&value).unwrap();
    let old_id = command_release_id(&old_document);
    let old_root = release_root.parent().unwrap().join(&old_id);
    fs::create_dir(&old_root).unwrap();
    fs::write(old_root.join("run.exe"), b"published executable").unwrap();
    fs::write(old_root.join("swawkit.release.json"), old_document).unwrap();
    fs::write(
        fixture
            .owner_data_root
            .join("_native/export/command/current"),
        format!("{old_id}\n"),
    )
    .unwrap();

    let error = fixture.resolve().unwrap_err().to_string();
    assert!(
        error.contains("unsupported command release schema"),
        "{error}"
    );
}
