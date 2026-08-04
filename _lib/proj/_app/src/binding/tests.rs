use super::*;
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    root: PathBuf,
    home: PathBuf,
    data_root: PathBuf,
    store: ProjectBindingStore,
}

impl Fixture {
    fn new() -> Self {
        let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let root =
            std::env::temp_dir().join(format!("swawkit-binding-{}-{sequence}", std::process::id()));
        let home = root.join("home");
        let data_root = home.join("data/proj.fixture");
        fs::create_dir_all(&data_root).expect("create fixture directories");
        let store = ProjectBindingStore::new(&home, &data_root);
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
fn distinguishes_missing_invalid_and_ready_bindings() {
    let fixture = Fixture::new();
    assert!(matches!(
        fixture.store.read(),
        ProjectBindingState::Missing { .. }
    ));

    fs::write(fixture.store.path(), "not-json").expect("write invalid binding");
    assert!(matches!(
        fixture.store.read(),
        ProjectBindingState::Invalid { .. }
    ));

    fixture
        .store
        .save(SWAWKIT_HOME_PLACEHOLDER)
        .expect("save binding");
    let ProjectBindingState::Ready(binding) = fixture.store.read() else {
        panic!("expected ready binding");
    };
    assert_eq!(binding.target_project_root(), fixture.home);
    assert_eq!(binding.action_root(), fixture.home.join(".swaw"));
}

#[test]
fn resolves_home_children_and_direct_absolute_paths() {
    let fixture = Fixture::new();
    let child = fixture.home.join("projects/example");
    let external = fixture.root.join("external");
    fs::create_dir_all(&child).expect("create home child");
    fs::create_dir_all(&external).expect("create external project");

    let child_binding = fixture
        .store
        .save("${SWAWKIT_HOME}/projects/example")
        .expect("save home child");
    assert_eq!(child_binding.target_project_root(), child);

    let external_binding = fixture
        .store
        .save(external.to_str().expect("Unicode fixture path"))
        .expect("save absolute project");
    assert_eq!(external_binding.target_project_root(), external);
}

#[test]
fn preserves_a_missing_external_target_for_repair() {
    let fixture = Fixture::new();
    let external = fixture.root.join("movable-project");
    fs::create_dir(&external).expect("create external project");
    let configured = external.to_str().expect("Unicode fixture path");
    fixture.store.save(configured).expect("save external binding");
    fs::remove_dir(&external).expect("move external project away");

    let ProjectBindingState::Invalid {
        configured_target_project_root,
        error,
        ..
    } = fixture.store.read()
    else {
        panic!("expected invalid binding");
    };
    assert_eq!(configured_target_project_root.as_deref(), Some(configured));
    assert!(error.contains("does not exist"));
}

#[test]
fn rejects_ambiguous_or_unsafe_path_expressions_without_overwriting() {
    let fixture = Fixture::new();
    fixture
        .store
        .save(SWAWKIT_HOME_PLACEHOLDER)
        .expect("save initial binding");
    let original = fs::read(fixture.store.path()).expect("read initial binding");

    for invalid in [
        "",
        " relative",
        "relative",
        "${PATH}",
        "${SWAWKIT_HOME}child",
        "${SWAWKIT_HOME}/../outside",
    ] {
        assert!(fixture.store.save(invalid).is_err(), "accepted {invalid:?}");
        assert_eq!(
            fs::read(fixture.store.path()).expect("read preserved binding"),
            original
        );
    }
}

#[test]
fn publishes_the_small_stable_record_contract() {
    let fixture = Fixture::new();
    fixture
        .store
        .save(SWAWKIT_HOME_PLACEHOLDER)
        .expect("save binding");
    let document: serde_json::Value =
        serde_json::from_slice(&fs::read(fixture.store.path()).unwrap()).unwrap();

    assert_eq!(document["schema"], BINDING_SCHEMA);
    assert_eq!(document["targetProjectRoot"], SWAWKIT_HOME_PLACEHOLDER);
    assert_eq!(document.as_object().map(|value| value.len()), Some(2));
    assert!(fs::read_dir(&fixture.data_root).unwrap().all(|item| {
        !item
            .unwrap()
            .file_name()
            .to_string_lossy()
            .contains(".swawkit.")
    }));
}
