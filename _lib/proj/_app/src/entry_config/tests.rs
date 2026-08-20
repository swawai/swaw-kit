use std::fs;
use std::sync::atomic::{AtomicU64, Ordering};

use super::*;
use crate::binding::SWAWKIT_HOME_PLACEHOLDER;

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    root: PathBuf,
    home: PathBuf,
    data_root: PathBuf,
    store: EntryConfigStore,
}

impl Fixture {
    fn new() -> Self {
        let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "swawkit-entry-config-{}-{sequence}",
            std::process::id()
        ));
        let home = root.join("home");
        let data_root = home.join("data/proj.fixture");
        fs::create_dir_all(&data_root).unwrap();
        let store = EntryConfigStore::new(&home, &data_root);
        Self {
            root,
            home,
            data_root,
            store,
        }
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn missing_config_is_a_valid_unbound_default() {
    let fixture = Fixture::new();
    let state = fixture.store.read();
    assert!(matches!(state, EntryConfigState::Default { .. }));
    assert_eq!(state.language(), EntryLanguage::ZhCn);
    assert!(state.binding().is_none());

    let document = fixture.store.document();
    assert_eq!(document.status, "default");
    assert_eq!(document.revision, "missing");
    assert_eq!(document.config.project_root, None);
    assert_eq!(document.settings[PROJECT_ROOT_ADDRESS], None);
}

#[test]
fn saves_a_strict_nullable_project_binding() {
    let fixture = Fixture::new();
    let mut record = EntryConfigRecord::default();
    record.project_root = Some(SWAWKIT_HOME_PLACEHOLDER.to_owned());
    record.language = "en".to_owned();
    let config = fixture.store.save(record).unwrap();

    assert_eq!(config.language(), EntryLanguage::En);
    assert_eq!(
        config.binding().unwrap().project_root(),
        fixture.home.as_path()
    );
    assert!(fixture.data_root.join(ENTRY_CONFIG_FILE).is_file());
}

#[test]
fn old_profile_and_unknown_fields_fail_closed() {
    let fixture = Fixture::new();
    fs::write(
        fixture.store.path(),
        br#"{"schema":"swawkit.entry-profile/v4","language":"zh-CN","targetProjectRoot":"${SWAWKIT_HOME}","development":{}}"#,
    )
    .unwrap();
    assert!(matches!(
        fixture.store.read(),
        EntryConfigState::Invalid { .. }
    ));
    assert!(fixture.store.read().binding().is_none());
}

#[test]
fn nullable_project_root_is_still_a_required_protocol_field() {
    let fixture = Fixture::new();
    fs::write(
        fixture.store.path(),
        br#"{"schema":"swawkit.entry-config/v1","language":"zh-CN"}"#,
    )
    .unwrap();

    assert!(matches!(
        fixture.store.read(),
        EntryConfigState::Invalid { .. }
    ));
}

#[test]
fn oversized_stored_config_is_invalid_and_can_be_atomically_replaced() {
    let fixture = Fixture::new();
    fs::write(
        fixture.store.path(),
        vec![b'x'; ENTRY_CONFIG_MAX_BYTES as usize + 1],
    )
    .unwrap();

    let state = fixture.store.read();
    assert!(matches!(state, EntryConfigState::Invalid { .. }));
    assert_eq!(state.language(), EntryLanguage::ZhCn);
    assert!(state.binding().is_none());
    let document = fixture.store.document();
    assert_eq!(document.status, "invalid");
    assert_eq!(document.config, EntryConfigRecord::default());
    assert!(
        document
            .error
            .as_deref()
            .is_some_and(|error| error.contains("no larger than 65536 bytes"))
    );

    let repaired = fixture.store.replace(EntryConfigRecord::default()).unwrap();
    assert_eq!(repaired.status, "ready");
    assert!(fs::metadata(fixture.store.path()).unwrap().len() <= ENTRY_CONFIG_MAX_BYTES);
}

#[test]
fn project_root_can_be_cleared_without_changing_language() {
    let fixture = Fixture::new();
    fixture
        .store
        .update_setting(
            PROJECT_ROOT_ADDRESS,
            Some(SWAWKIT_HOME_PLACEHOLDER.to_owned()),
        )
        .unwrap();
    let document = fixture
        .store
        .update_setting(PROJECT_ROOT_ADDRESS, None)
        .unwrap();

    assert_eq!(document.config.language, DEFAULT_LANGUAGE);
    assert_eq!(document.config.project_root, None);
    assert_eq!(document.resolved_project_root, None);
}

#[test]
fn setting_updates_are_revision_guarded() {
    let fixture = Fixture::new();
    let initial = fixture.store.document();
    let saved = fixture
        .store
        .update_setting_if_revision(&initial.revision, LANGUAGE_ADDRESS, Some("en".to_owned()))
        .unwrap();
    assert_eq!(saved.config.language, "en");

    assert!(matches!(
        fixture.store.update_setting_if_revision(
            &initial.revision,
            LANGUAGE_ADDRESS,
            Some("zh-CN".to_owned()),
        ),
        Err(EntryConfigUpdateError::Conflict { .. })
    ));
}

#[test]
fn unavailable_binding_preserves_language_and_can_be_repaired() {
    let fixture = Fixture::new();
    let project = fixture.root.join("project");
    fs::create_dir(&project).unwrap();
    let mut record = EntryConfigRecord::default();
    record.language = "en".to_owned();
    record.project_root = Some(project.display().to_string());
    fixture.store.save(record).unwrap();
    fs::remove_dir(&project).unwrap();

    let state = fixture.store.read();
    assert_eq!(state.language(), EntryLanguage::En);
    assert!(state.binding().is_none());
    let document = fixture.store.document();
    assert_eq!(document.status, "bindingUnavailable");
    assert!(
        document
            .error
            .as_deref()
            .is_some_and(|error| error.contains("does not exist"))
    );

    let repaired = fixture
        .store
        .update_setting(
            PROJECT_ROOT_ADDRESS,
            Some(SWAWKIT_HOME_PLACEHOLDER.to_owned()),
        )
        .unwrap();
    assert_eq!(repaired.status, "ready");
    assert_eq!(repaired.config.language, "en");
}
