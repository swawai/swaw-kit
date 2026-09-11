use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use serde_json::Value;

use super::super::provider::SetupProvider;
use super::*;

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    root: PathBuf,
    data_root: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "swawkit-dev-settings-{}-{sequence}",
            std::process::id()
        ));
        let data_root = root.join("data/proj.fixture");
        fs::create_dir_all(&data_root).unwrap();
        Self { root, data_root }
    }

    fn store(&self) -> DevSettingsStore {
        DevSettingsStore::new(&self.data_root)
    }

    fn state_path(&self) -> PathBuf {
        self.data_root.join("modules/system/dev/setup/_state.json")
    }

    fn setup_path(&self) -> PathBuf {
        self.data_root.join("modules/system/dev/setup")
    }

    fn legacy_setup_path(&self) -> PathBuf {
        self.data_root.join("modules/kernel/.dev/setup")
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn missing_settings_have_defined_defaults_without_writing() {
    let fixture = Fixture::new();
    let snapshot = fixture.store().snapshot().unwrap();
    assert_eq!(snapshot.revision(), "missing");
    assert_eq!(snapshot.settings(), &DevSettings::default());
    assert!(!snapshot.path.exists());
    assert!(snapshot.input_revision().starts_with("sha256-"));
}

#[test]
fn setting_is_atomic_cas_and_invalidates_changed_provider_inputs() {
    let fixture = Fixture::new();
    let store = fixture.store();
    let initial = store.snapshot().unwrap();
    let saved = store
        .update_setting(
            ".dev/bun/version",
            "1.2.16".to_owned(),
            Some(initial.revision()),
        )
        .unwrap();
    assert_ne!(saved.revision(), "missing");
    assert_eq!(saved.settings().bun.version, "1.2.16");
    let state: Value = serde_json::from_slice(&fs::read(fixture.state_path()).unwrap()).unwrap();
    assert_eq!(state["status"], "unavailable");
    assert_eq!(state["inputRevision"], saved.input_revision());

    let content = fs::read(&saved.path).unwrap();
    assert!(
        store
            .update_setting(".dev/bun/version", "1.2.17".to_owned(), Some("missing"))
            .unwrap_err()
            .contains("changed since revision")
    );
    assert_eq!(fs::read(&saved.path).unwrap(), content);
}

#[test]
fn persisting_an_equivalent_default_does_not_invalidate_a_ready_publication() {
    let fixture = Fixture::new();
    let store = fixture.store();
    let input = store.snapshot().unwrap().input_revision().to_owned();
    let provider = SetupProvider::new(&fixture.data_root, &input).unwrap();
    let attempt = provider.start().unwrap();
    provider.complete(&attempt).unwrap();
    let before = fs::read(fixture.state_path()).unwrap();
    let state: Value = serde_json::from_slice(&before).unwrap();
    assert_eq!(state["status"], "ready");

    store
        .update_setting(".dev/bun/version", "1.2.15".to_owned(), Some("missing"))
        .unwrap();
    assert_eq!(fs::read(fixture.state_path()).unwrap(), before);
}

#[test]
fn setter_migrates_legacy_setup_before_creating_current_state() {
    let fixture = Fixture::new();
    let store = fixture.store();
    let input = store.snapshot().unwrap().input_revision().to_owned();
    let provider = SetupProvider::new(&fixture.data_root, &input).unwrap();
    let attempt = provider.start().unwrap();
    provider.complete(&attempt).unwrap();

    let current = fixture.setup_path();
    let journal = current.join("_runs/legacy-run/state");
    fs::create_dir_all(journal.parent().unwrap()).unwrap();
    fs::write(&journal, "legacy journal").unwrap();
    let legacy = fixture.legacy_setup_path();
    fs::create_dir_all(legacy.parent().unwrap()).unwrap();
    fs::rename(&current, &legacy).unwrap();

    let saved = store
        .update_setting(".dev/bun/version", "1.2.16".to_owned(), Some("missing"))
        .unwrap();

    assert!(!legacy.exists());
    assert_eq!(
        fs::read_to_string(fixture.setup_path().join("_runs/legacy-run/state")).unwrap(),
        "legacy journal"
    );
    let state: Value = serde_json::from_slice(&fs::read(fixture.state_path()).unwrap()).unwrap();
    assert_eq!(state["status"], "unavailable");
    assert_eq!(state["inputRevision"], saved.input_revision());
    assert_eq!(saved.settings().bun.version, "1.2.16");
}

#[test]
fn all_ten_public_setters_are_backed_by_document_values() {
    let fixture = Fixture::new();
    let document = fixture.store().snapshot().unwrap().document();
    assert_eq!(setting_addresses().len(), 10);
    assert_eq!(document.values.len(), 10);
    assert!(
        setting_addresses()
            .iter()
            .all(|address| document.values.contains_key(address))
    );
}
