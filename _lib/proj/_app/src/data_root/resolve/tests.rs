use super::*;
use crate::entry::{ENTRY_ID_FILE_NAME, EntryId};
use std::fs;
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    root: PathBuf,
    home: PathBuf,
    entry: PathBuf,
    data_root: PathBuf,
}

impl Fixture {
    fn new(name: &str) -> Self {
        let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "swawkit-data-root-open-{}-{sequence}",
            std::process::id()
        ));
        let home = root.join("home");
        let entry = home.join(format!("{name}.exe"));
        let data_root = home.join("data").join(format!("proj.{name}"));
        fs::create_dir_all(&home).expect("create fixture home");
        fs::write(&entry, b"launcher").expect("create fixture Entry");
        Self {
            root,
            home,
            entry,
            data_root,
        }
    }

    fn request(&self) -> ResolveDataRootRequest<'_> {
        ResolveDataRootRequest {
            swawkit_home: &self.home,
            entry_file: &self.entry,
        }
    }

    fn initialize(&self) -> EntryId {
        fs::create_dir_all(&self.data_root).expect("create DataRoot");
        EntryId::create_once(&self.data_root).expect("create Entry ID")
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn opens_only_the_basename_owned_initialized_data_root() {
    let fixture = Fixture::new("project-one");
    let expected = fixture.initialize();

    let resolved = resolve_data_root(fixture.request()).expect("open DataRoot");
    assert_eq!(resolved.path(), fixture.data_root);
    assert_eq!(resolved.entry_id(), &expected);
    assert_eq!(resolved.runtime_root(), fixture.data_root.join("runtime"));
}

#[test]
fn canonicalizes_the_manager_entry_name() {
    let fixture = Fixture::new("SwAwKiT");
    let canonical = fixture.home.join("data/proj.swawkit");
    fs::create_dir_all(&canonical).expect("create canonical manager DataRoot");
    let expected = EntryId::create_once(&canonical).expect("create manager Entry ID");

    let resolved = resolve_data_root(fixture.request()).expect("open manager DataRoot");
    assert_eq!(resolved.path(), canonical);
    assert_eq!(resolved.entry_id(), &expected);
}

#[test]
fn replacing_the_launcher_does_not_change_instance_identity() {
    let fixture = Fixture::new("replaceable");
    let expected = fixture.initialize();
    let first = resolve_data_root(fixture.request()).expect("first open");
    drop(first);

    fs::remove_file(&fixture.entry).expect("remove old Launcher");
    fs::write(&fixture.entry, b"replacement Launcher").expect("replace Launcher");

    let second = resolve_data_root(fixture.request()).expect("open after replacement");
    assert_eq!(second.entry_id(), &expected);
}

#[test]
fn rename_and_copy_select_only_their_own_basename() {
    let fixture = Fixture::new("alpha");
    let alpha_id = fixture.initialize();
    let beta_entry = fixture.home.join("beta.exe");
    fs::copy(&fixture.entry, &beta_entry).expect("copy Launcher");

    let beta_request = ResolveDataRootRequest {
        swawkit_home: &fixture.home,
        entry_file: &beta_entry,
    };
    assert_eq!(
        resolve_data_root(beta_request).unwrap_err().kind(),
        ResolveDataRootErrorKind::Uninitialized
    );
    let beta_root = fixture.home.join("data/proj.beta");
    fs::create_dir(&beta_root).expect("create beta DataRoot");
    let beta_id = EntryId::create_once(&beta_root).expect("create beta Entry ID");
    assert_ne!(alpha_id, beta_id);
    assert_eq!(
        resolve_data_root(beta_request).unwrap().entry_id(),
        &beta_id
    );
    assert_eq!(
        resolve_data_root(fixture.request()).unwrap().entry_id(),
        &alpha_id
    );
}

#[test]
fn missing_legacy_unmanaged_and_invalid_states_are_distinct() {
    let fixture = Fixture::new("states");
    assert_eq!(
        resolve_data_root(fixture.request()).unwrap_err().kind(),
        ResolveDataRootErrorKind::Uninitialized
    );

    fs::create_dir_all(&fixture.data_root).expect("create unmanaged DataRoot");
    assert_eq!(
        resolve_data_root(fixture.request()).unwrap_err().kind(),
        ResolveDataRootErrorKind::UnmanagedDataRoot
    );

    fs::write(fixture.data_root.join("_entry.json"), b"legacy").expect("write legacy marker");
    assert_eq!(
        resolve_data_root(fixture.request()).unwrap_err().kind(),
        ResolveDataRootErrorKind::LegacyMigrationRequired
    );

    fs::write(
        fixture.data_root.join(ENTRY_ID_FILE_NAME),
        format!("{}\n", "A".repeat(64)),
    )
    .expect("write invalid Entry ID");
    assert_eq!(
        resolve_data_root(fixture.request()).unwrap_err().kind(),
        ResolveDataRootErrorKind::Invalid
    );
}

#[test]
fn rejects_a_reparse_point_data_ancestor() {
    use std::os::windows::fs::symlink_dir;

    let fixture = Fixture::new("ancestor-reparse");
    let external_data = fixture.root.join("external-data");
    let external_root = external_data.join("proj.ancestor-reparse");
    fs::create_dir_all(&external_root).expect("create external DataRoot");
    EntryId::create_once(&external_root).expect("create external Entry ID");
    match symlink_dir(&external_data, fixture.home.join("data")) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied => return,
        Err(error) => panic!("create data ancestor reparse point: {error}"),
    }

    assert_eq!(
        resolve_data_root(fixture.request()).unwrap_err().kind(),
        ResolveDataRootErrorKind::Invalid
    );
    fs::remove_dir(fixture.home.join("data")).expect("remove data ancestor reparse point");
}

#[test]
fn rejects_entries_outside_home_or_without_an_exe_suffix() {
    let fixture = Fixture::new("layout");
    let outside = fixture.root.join("outside.exe");
    fs::write(&outside, b"launcher").expect("write outside Entry");
    let outside_request = ResolveDataRootRequest {
        swawkit_home: &fixture.home,
        entry_file: &outside,
    };
    assert_eq!(
        resolve_data_root(outside_request).unwrap_err().kind(),
        ResolveDataRootErrorKind::Invalid
    );

    let wrong_suffix = fixture.home.join("layout.txt");
    fs::write(&wrong_suffix, b"launcher").expect("write wrong-suffix Entry");
    let wrong_suffix_request = ResolveDataRootRequest {
        swawkit_home: &fixture.home,
        entry_file: &wrong_suffix,
    };
    assert_eq!(
        resolve_data_root(wrong_suffix_request).unwrap_err().kind(),
        ResolveDataRootErrorKind::Invalid
    );
}

#[test]
fn an_open_session_pins_the_data_root_and_entry_id() {
    let fixture = Fixture::new("pinned");
    fixture.initialize();
    let resolved = resolve_data_root(fixture.request()).expect("open DataRoot");
    let moved = fixture.home.join("data/proj.moved");

    assert!(fs::rename(&fixture.data_root, &moved).is_err());
    assert!(fs::write(fixture.data_root.join(ENTRY_ID_FILE_NAME), b"changed").is_err());

    drop(resolved);
    fs::rename(&fixture.data_root, &moved).expect("move released DataRoot");
}
