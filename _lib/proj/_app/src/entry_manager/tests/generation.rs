use std::fs;

use crate::runtime_release::RuntimeReleaseStore;

use super::{EntryManagerErrorKind, EntryStatus, Fixture};

#[test]
fn incomplete_create_converges_runtime_receipt_and_launcher_to_one_generation() {
    let mut fixture = Fixture::new();
    fixture.manager().create("version-retry").unwrap();
    fs::remove_file(fixture.entry_file("version-retry")).unwrap();
    let old_release = fixture.context.release_id.clone();
    let new_release = publish_next_generation(&mut fixture, true);

    let incomplete = fixture.manager().inspect("version-retry").unwrap();
    assert_eq!(incomplete.entry.status, EntryStatus::Incomplete);
    assert_eq!(
        incomplete.entry.release_id.as_deref(),
        Some(old_release.as_str())
    );

    let completed = fixture.manager().create("version-retry").unwrap();
    assert!(completed.changed);
    assert_eq!(completed.entry.status, EntryStatus::Ready);
    assert_eq!(
        completed.entry.release_id.as_deref(),
        Some(new_release.as_str())
    );
    assert_eq!(
        fs::read(fixture.entry_file("version-retry")).unwrap(),
        b"new manager Launcher"
    );
    assert_eq!(
        fs::read_to_string(fixture.data_root("version-retry").join("runtime/current"))
            .unwrap()
            .trim(),
        new_release
    );
}

#[test]
fn migration_retry_moves_an_uncommitted_runtime_to_the_running_release() {
    let mut fixture = Fixture::new();
    fixture.legacy("generation-retry");
    let old_release = fixture.context.release_id.clone();
    let source = RuntimeReleaseStore::open(&fixture.context.runtime_root, &fixture.home).unwrap();
    let target = RuntimeReleaseStore::initialize(
        &fixture.data_root("generation-retry").join("runtime"),
        &fixture.home,
    )
    .unwrap();
    target.publish_clone_from(&source, &old_release).unwrap();
    target.select(&old_release).unwrap();
    let new_release = publish_next_generation(&mut fixture, true);

    let migrated = fixture.manager().migrate("generation-retry").unwrap();
    assert_eq!(migrated.entry.status, EntryStatus::Ready);
    assert_eq!(
        migrated.entry.release_id.as_deref(),
        Some(new_release.as_str())
    );
    assert_ne!(
        migrated.entry.release_id.as_deref(),
        Some(old_release.as_str())
    );
    assert_eq!(
        fs::read(fixture.entry_file("generation-retry")).unwrap(),
        b"new manager Launcher"
    );
}

#[test]
fn stale_manager_host_rejects_create_and_migrate_before_target_writes() {
    let mut fixture = Fixture::new();
    fixture.legacy("stale-migrate");
    let legacy_record = fs::read(fixture.data_root("stale-migrate").join("_entry.json")).unwrap();
    let legacy_launcher = fs::read(fixture.entry_file("stale-migrate")).unwrap();
    let running_release = fixture.context.release_id.clone();
    let selected_release = publish_next_generation(&mut fixture, false);
    assert_ne!(running_release, selected_release);

    assert_eq!(
        fixture.manager().create("stale-create").unwrap_err().kind(),
        EntryManagerErrorKind::Conflict
    );
    assert!(!fixture.entry_file("stale-create").exists());
    assert!(!fixture.data_root("stale-create").exists());

    assert_eq!(
        fixture
            .manager()
            .migrate("stale-migrate")
            .unwrap_err()
            .kind(),
        EntryManagerErrorKind::Conflict
    );
    assert_eq!(
        fs::read(fixture.data_root("stale-migrate").join("_entry.json")).unwrap(),
        legacy_record
    );
    assert_eq!(
        fs::read(fixture.entry_file("stale-migrate")).unwrap(),
        legacy_launcher
    );
    let members = fs::read_dir(fixture.data_root("stale-migrate"))
        .unwrap()
        .map(|item| item.unwrap().file_name().to_string_lossy().into_owned())
        .collect::<Vec<_>>();
    assert_eq!(members, ["_entry.json"]);
}

#[test]
fn ready_create_and_migrate_retries_do_not_depend_on_manager_generation() {
    let mut fixture = Fixture::new();
    let created = fixture.manager().create("ready-create").unwrap();
    fixture.legacy("ready-migrate");
    let migrated = fixture.manager().migrate("ready-migrate").unwrap();
    fs::remove_file(fixture.data_root("ready-migrate").join("_entry.json")).unwrap();
    let selected_release = publish_next_generation(&mut fixture, false);
    assert_ne!(fixture.context.release_id, selected_release);
    fs::remove_file(&fixture.context.entry_file).unwrap();

    let create_retry = fixture.manager().create("ready-create").unwrap();
    assert!(!create_retry.changed);
    assert_eq!(create_retry.entry.entry_id, created.entry.entry_id);
    assert_eq!(create_retry.entry.release_id, created.entry.release_id);

    let migrate_retry = fixture.manager().migrate("ready-migrate").unwrap();
    assert!(!migrate_retry.changed);
    assert_eq!(migrate_retry.entry.entry_id, migrated.entry.entry_id);
    assert_eq!(migrate_retry.entry.release_id, migrated.entry.release_id);
}

fn publish_next_generation(fixture: &mut Fixture, restart_host: bool) -> String {
    let releases = fixture.context.runtime_root.join("releases");
    let release_id = crate::runtime_release::tests::write_release(
        &fixture.home,
        &releases,
        &[
            ("swawkit-proj.exe", b"new-core"),
            ("swawkit-proj-host.exe", b"new-host"),
            ("swawkit-proj-module.exe", b"new-module"),
            ("swawkit-proj-dev.exe", b"new-dev"),
        ],
    );
    // This is the one supported updater order. Updating EntryContext models
    // the manager Host restart that follows publication.
    fs::write(
        fixture.context.runtime_root.join("current"),
        format!("{release_id}\n"),
    )
    .unwrap();
    fs::write(&fixture.context.entry_file, b"new manager Launcher").unwrap();
    if restart_host {
        fixture.context.release_id = release_id.clone();
        fixture.context.product_executable = releases.join(&release_id).join("swawkit-proj.exe");
    }
    release_id
}
