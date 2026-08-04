use super::*;
use std::fs;
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    root: PathBuf,
    home: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "swawkit-project-binding-{}-{sequence}",
            std::process::id()
        ));
        let home = root.join("home");
        fs::create_dir_all(&home).expect("create fixture home");
        Self { root, home }
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn resolves_home_children_and_direct_absolute_paths() {
    let fixture = Fixture::new();
    let child = fixture.home.join("projects/example");
    let external = fixture.root.join("external");
    fs::create_dir_all(&child).expect("create home child");
    fs::create_dir_all(&external).expect("create external project");

    let home = ProjectBinding::resolve(&fixture.home, SWAWKIT_HOME_PLACEHOLDER)
        .expect("resolve home binding");
    assert_eq!(home.target_project_root(), fixture.home);
    assert_eq!(home.action_root(), fixture.home.join(".swaw"));

    let child_binding = ProjectBinding::resolve(&fixture.home, "${SWAWKIT_HOME}/projects/example")
        .expect("resolve home child");
    assert_eq!(child_binding.target_project_root(), child);

    let external_binding = ProjectBinding::resolve(
        &fixture.home,
        external.to_str().expect("Unicode fixture path"),
    )
    .expect("resolve absolute project");
    assert_eq!(external_binding.target_project_root(), external);
}

#[test]
fn rejects_ambiguous_unsafe_or_missing_targets() {
    let fixture = Fixture::new();
    for invalid in [
        "",
        " relative",
        "relative",
        "${PATH}",
        "${SWAWKIT_HOME}child",
        "${SWAWKIT_HOME}/../outside",
        "${SWAWKIT_HOME}/missing",
    ] {
        assert!(
            ProjectBinding::resolve(&fixture.home, invalid).is_err(),
            "accepted {invalid:?}"
        );
    }
}
