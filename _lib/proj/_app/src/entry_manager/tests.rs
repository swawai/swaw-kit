use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use serde_json::json;

use super::*;
use crate::context::EntryContext;
use crate::entry::EntryId;

mod generation;
mod receipt_binding;

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    root: PathBuf,
    home: PathBuf,
    context: EntryContext,
}

impl Fixture {
    fn new() -> Self {
        let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "swawkit-entry-manager-{}-{sequence}",
            std::process::id()
        ));
        let home = root.join("home");
        let data_root = home.join("data/proj.swawkit");
        let runtime_root = data_root.join("runtime");
        fs::create_dir_all(runtime_root.join("releases")).unwrap();
        let release_id = crate::runtime_release::tests::write_release(
            &home,
            &runtime_root.join("releases"),
            &[
                ("swawkit-proj.exe", b"core"),
                ("swawkit-proj-host.exe", b"host"),
                ("swawkit-proj-module.exe", b"module"),
                ("swawkit-proj-dev.exe", b"dev"),
            ],
        );
        fs::write(runtime_root.join("current"), format!("{release_id}\n")).unwrap();
        let entry_file = home.join("swawkit.exe");
        fs::write(&entry_file, b"thin manager Launcher").unwrap();
        let entry_id = EntryId::create_once(&data_root).unwrap();
        let context = EntryContext {
            swawkit_home: home.clone(),
            data_root: data_root.clone(),
            runtime_root: runtime_root.clone(),
            entry_file,
            entry_name: "swawkit".to_owned(),
            entry_id,
            invocation_directory: root.clone(),
            product_executable: runtime_root
                .join("releases")
                .join(&release_id)
                .join("swawkit-proj.exe"),
            release_id,
        };
        Self {
            root,
            home,
            context,
        }
    }

    fn manager(&self) -> EntryManager<'_> {
        EntryManager::new(&self.context)
    }

    fn data_root(&self, name: &str) -> PathBuf {
        self.home.join("data").join(format!("proj.{name}"))
    }

    fn entry_file(&self, name: &str) -> PathBuf {
        self.home.join(format!("{name}.exe"))
    }

    fn legacy(&self, name: &str) {
        let root = self.data_root(name);
        fs::create_dir(&root).unwrap();
        fs::write(self.entry_file(name), b"legacy Launcher").unwrap();
        fs::write(
            root.join("_entry.json"),
            serde_json::to_vec(&json!({
                "schema": "swawkit.proj-entry.v0",
                "entryName": name,
                "entryFile": format!("{name}.exe"),
                "volumeId": r"\\?\Volume{01234567-89ab-cdef-0123-456789abcdef}",
                "fileId": "0123456789abcdef",
            }))
            .unwrap(),
        )
        .unwrap();
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn wire_protocol_names_are_stable() {
    assert_eq!(ENTRY_INVENTORY_PROTOCOL, "swawkit.entry-inventory/v1");
    assert_eq!(
        ENTRY_INSTANCE_STATE_PROTOCOL,
        "swawkit.entry-instance-state/v1"
    );
    assert_eq!(
        ENTRY_INSTANCE_MUTATION_PROTOCOL,
        "swawkit.entry-instance-mutation/v1"
    );
}

#[test]
fn fresh_create_is_ready_idempotent_and_has_independent_runtime_bytes() {
    let fixture = Fixture::new();
    let created = fixture.manager().create("proj1").unwrap();
    assert!(created.changed);
    assert_eq!(created.entry.status, EntryStatus::Ready);
    let first_id = created.entry.entry_id.clone();

    let repeated = fixture.manager().create("proj1").unwrap();
    assert!(!repeated.changed);
    assert_eq!(repeated.entry.entry_id, first_id);
    assert_eq!(fixture.manager().inventory().unwrap().entries.len(), 1);

    let source_core = fixture
        .context
        .runtime_root
        .join("releases")
        .join(&fixture.context.release_id)
        .join("swawkit-proj.exe");
    fs::write(source_core, b"corrupted source after clone").unwrap();
    assert_eq!(
        fixture.manager().inspect("proj1").unwrap().entry.status,
        EntryStatus::Ready
    );
}

#[test]
fn create_retries_the_only_safe_post_data_root_commit_state() {
    let fixture = Fixture::new();
    fixture.manager().create("retry-one").unwrap();
    fs::remove_file(fixture.entry_file("retry-one")).unwrap();

    let incomplete = fixture.manager().inspect("retry-one").unwrap();
    assert_eq!(incomplete.entry.status, EntryStatus::Incomplete);
    let completed = fixture.manager().create("retry-one").unwrap();
    assert!(completed.changed);
    assert_eq!(completed.entry.status, EntryStatus::Ready);
}

#[test]
fn strict_legacy_migration_is_forward_only_and_idempotent() {
    let fixture = Fixture::new();
    fixture.legacy("legacy-one");
    assert_eq!(
        fixture
            .manager()
            .inspect("legacy-one")
            .unwrap()
            .entry
            .status,
        EntryStatus::LegacyMigrationRequired
    );

    // This is the safe crash point after replacing the Launcher but before
    // publishing its receipt and the final entry.id commit marker.
    fs::copy(
        &fixture.context.entry_file,
        fixture.entry_file("legacy-one"),
    )
    .unwrap();
    assert_eq!(
        fixture
            .manager()
            .inspect("legacy-one")
            .unwrap()
            .entry
            .status,
        EntryStatus::LegacyMigrationRequired
    );

    let migrated = fixture.manager().migrate("legacy-one").unwrap();
    assert!(migrated.changed);
    assert_eq!(migrated.entry.status, EntryStatus::Ready);
    assert!(
        fixture
            .data_root("legacy-one")
            .join("_entry.json")
            .is_file()
    );
    assert!(!fixture.manager().migrate("legacy-one").unwrap().changed);
}

#[test]
fn invalid_legacy_foreign_launcher_and_reparse_are_conflicts() {
    let fixture = Fixture::new();
    fixture.legacy("invalid-legacy");
    fs::write(
        fixture.data_root("invalid-legacy").join("_entry.json"),
        br#"{"schema":"swawkit.proj-entry.v0","entryName":"other"}"#,
    )
    .unwrap();
    assert_eq!(
        fixture
            .manager()
            .inspect("invalid-legacy")
            .unwrap()
            .entry
            .status,
        EntryStatus::Conflict
    );
    assert_eq!(
        fixture
            .manager()
            .migrate("invalid-legacy")
            .unwrap_err()
            .kind(),
        EntryManagerErrorKind::Conflict
    );

    fs::write(fixture.entry_file("foreign"), b"foreign").unwrap();
    assert_eq!(
        fixture.manager().create("foreign").unwrap_err().kind(),
        EntryManagerErrorKind::Conflict
    );

    let external = fixture.root.join("external");
    fs::create_dir(&external).unwrap();
    let reparse = fixture.data_root("unsafe-one");
    if std::os::windows::fs::symlink_dir(&external, &reparse).is_ok() {
        assert_eq!(
            fixture
                .manager()
                .inspect("unsafe-one")
                .unwrap()
                .entry
                .status,
            EntryStatus::Conflict
        );
        assert!(fixture.manager().create("unsafe-one").is_err());
        fs::remove_dir(reparse).unwrap();
    }
}

#[test]
fn inventory_reports_non_canonical_members_instead_of_claiming_them() {
    let fixture = Fixture::new();
    fs::write(fixture.home.join("Mixed-Case.EXE"), b"foreign").unwrap();
    fs::create_dir(fixture.home.join("data/proj.bad_name")).unwrap();

    let inventory = fixture.manager().inventory().unwrap();
    let mixed_case = inventory
        .entries
        .iter()
        .find(|entry| entry.entry_name == "mixed-case")
        .unwrap();
    assert_eq!(mixed_case.status, EntryStatus::Conflict);
    assert!(
        mixed_case
            .issues
            .iter()
            .any(|issue| issue.contains("non-canonical"))
    );

    let invalid_name = inventory
        .entries
        .iter()
        .find(|entry| entry.entry_name == "bad_name")
        .unwrap();
    assert_eq!(invalid_name.status, EntryStatus::Conflict);
    assert!(
        invalid_name
            .issues
            .iter()
            .any(|issue| issue.contains("lower-kebab"))
    );
}

#[test]
fn mutations_reject_case_insensitive_namespace_collisions() {
    let fixture = Fixture::new();
    fs::write(fixture.home.join("Case-One.EXE"), b"foreign").unwrap();
    assert_eq!(
        fixture.manager().create("case-one").unwrap_err().kind(),
        EntryManagerErrorKind::Conflict
    );

    fs::create_dir(fixture.home.join("data/proj.Case-Two")).unwrap();
    assert_eq!(
        fixture.manager().create("case-two").unwrap_err().kind(),
        EntryManagerErrorKind::Conflict
    );
}

#[test]
fn every_public_operation_checks_manager_authority_before_input() {
    let fixture = Fixture::new();
    let mut ordinary = fixture.context.clone();
    ordinary.entry_name = "ordinary".to_owned();
    let manager = EntryManager::new(&ordinary);

    assert_eq!(
        manager.inventory().unwrap_err().kind(),
        EntryManagerErrorKind::ManagerOnly
    );
    assert_eq!(
        manager.inspect("INVALID").unwrap_err().kind(),
        EntryManagerErrorKind::ManagerOnly
    );
    assert_eq!(
        manager.create("INVALID").unwrap_err().kind(),
        EntryManagerErrorKind::ManagerOnly
    );
    assert_eq!(
        manager.migrate("INVALID").unwrap_err().kind(),
        EntryManagerErrorKind::ManagerOnly
    );
}
