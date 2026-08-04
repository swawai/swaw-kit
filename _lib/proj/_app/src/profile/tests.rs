use super::*;
use crate::binding::SWAWKIT_HOME_PLACEHOLDER;
use serde_json::Value;
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    root: PathBuf,
    home: PathBuf,
    data_root: PathBuf,
    store: EntryProfileStore,
}

impl Fixture {
    fn new() -> Self {
        let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let root =
            std::env::temp_dir().join(format!("swawkit-profile-{}-{sequence}", std::process::id()));
        let home = root.join("home");
        let data_root = home.join("data/proj.fixture");
        fs::create_dir_all(&data_root).expect("create fixture directories");
        let store = EntryProfileStore::new(&home, &data_root);
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
fn distinguishes_missing_invalid_and_ready_profiles() {
    let fixture = Fixture::new();
    assert!(matches!(
        fixture.store.read(),
        EntryProfileState::Missing { .. }
    ));

    fs::write(fixture.store.path(), "not-json").expect("write invalid profile");
    assert!(matches!(
        fixture.store.read(),
        EntryProfileState::Invalid { .. }
    ));

    fixture
        .store
        .save(EntryProfileRecord::default())
        .expect("save profile");
    let EntryProfileState::Ready(profile) = fixture.store.read() else {
        panic!("expected ready profile");
    };
    assert_eq!(profile.binding().target_project_root(), fixture.home);
    assert_eq!(profile.binding().action_root(), fixture.home.join(".swaw"));
}

#[test]
fn saves_the_complete_explicit_profile_atomically() {
    let fixture = Fixture::new();
    let profile = EntryProfileRecord::default();
    fixture.store.save(profile).expect("save profile");
    let document: Value = serde_json::from_slice(&fs::read(fixture.store.path()).unwrap()).unwrap();

    assert_eq!(document["schema"], PROFILE_SCHEMA);
    assert_eq!(document["targetProjectRoot"], SWAWKIT_HOME_PLACEHOLDER);
    assert_eq!(document["development"]["rust"]["profile"], "minimal");
    assert_eq!(document["git"]["name"], "");
    assert!(fs::read_dir(&fixture.data_root).unwrap().all(|item| {
        !item
            .unwrap()
            .file_name()
            .to_string_lossy()
            .contains(".swawkit.")
    }));
}

#[test]
fn rejects_invalid_conditional_fields_without_overwriting() {
    let fixture = Fixture::new();
    fixture
        .store
        .save(EntryProfileRecord::default())
        .expect("save initial profile");
    let original = fs::read(fixture.store.path()).expect("read initial profile");

    let mut invalid = EntryProfileRecord::default();
    invalid.development.bun.version.clear();
    assert!(fixture.store.save(invalid).is_err());
    assert_eq!(fs::read(fixture.store.path()).unwrap(), original);

    let mut invalid = EntryProfileRecord::default();
    invalid.development.rust.host = "aarch64-pc-windows-msvc".to_owned();
    assert!(fixture.store.save(invalid).is_err());
    assert_eq!(fs::read(fixture.store.path()).unwrap(), original);

    let mut invalid = EntryProfileRecord::default();
    invalid.development.uv.mode = "managed".to_owned();
    assert!(fixture.store.save(invalid).is_err());
    assert_eq!(fs::read(fixture.store.path()).unwrap(), original);
}

#[test]
fn preserves_a_valid_document_when_its_target_moves() {
    let fixture = Fixture::new();
    let external = fixture.root.join("movable-project");
    fs::create_dir(&external).expect("create external project");
    let mut record = EntryProfileRecord::default();
    record.target_project_root = external.to_string_lossy().into_owned();
    fixture.store.save(record).expect("save external profile");
    fs::remove_dir(&external).expect("move external project away");

    let EntryProfileState::Invalid {
        record: Some(record),
        error,
        ..
    } = fixture.store.read()
    else {
        panic!("expected invalid profile");
    };
    assert_eq!(record.target_project_root, external.to_string_lossy());
    assert!(error.contains("does not exist"));
}
