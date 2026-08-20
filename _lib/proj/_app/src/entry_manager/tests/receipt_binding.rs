use std::fs;
use std::path::Path;

use super::super::launcher::LauncherArtifact;
use super::{EntryManagerErrorKind, EntryStatus, Fixture};

#[test]
fn copied_incomplete_data_root_cannot_be_adopted_under_another_name() {
    let fixture = Fixture::new();
    fixture.manager().create("alpha").unwrap();
    fs::remove_file(fixture.entry_file("alpha")).unwrap();
    copy_tree(&fixture.data_root("alpha"), &fixture.data_root("beta"));

    assert_eq!(
        fixture.manager().inspect("beta").unwrap().entry.status,
        EntryStatus::Conflict
    );
    assert_eq!(
        fixture.manager().create("beta").unwrap_err().kind(),
        EntryManagerErrorKind::Conflict
    );
    assert!(!fixture.entry_file("beta").exists());
}

#[test]
fn copied_ready_instance_and_launcher_cannot_be_adopted_under_another_name() {
    let fixture = Fixture::new();
    fixture.manager().create("gamma").unwrap();
    copy_tree(&fixture.data_root("gamma"), &fixture.data_root("delta"));
    fs::copy(fixture.entry_file("gamma"), fixture.entry_file("delta")).unwrap();

    assert_eq!(
        fixture.manager().inspect("delta").unwrap().entry.status,
        EntryStatus::Conflict
    );
    assert_eq!(
        fixture.manager().create("delta").unwrap_err().kind(),
        EntryManagerErrorKind::Conflict
    );
}

#[test]
fn receipt_entry_name_mismatch_is_rejected_for_ready_and_legacy_partial_states() {
    let fixture = Fixture::new();
    fixture.manager().create("bound-ready").unwrap();
    let receipt_path = fixture.data_root("bound-ready").join("launcher.json");
    let mut receipt: serde_json::Value =
        serde_json::from_slice(&fs::read(&receipt_path).unwrap()).unwrap();
    receipt["entryName"] = serde_json::Value::String("other".to_owned());
    fs::write(&receipt_path, serde_json::to_vec_pretty(&receipt).unwrap()).unwrap();
    assert_eq!(
        fixture
            .manager()
            .inspect("bound-ready")
            .unwrap()
            .entry
            .status,
        EntryStatus::Conflict
    );

    fixture.legacy("bound-legacy");
    LauncherArtifact::read(&fixture.context.entry_file)
        .unwrap()
        .publish_receipt_replace(&fixture.data_root("bound-legacy"), "other")
        .unwrap();
    assert_eq!(
        fixture
            .manager()
            .inspect("bound-legacy")
            .unwrap()
            .entry
            .status,
        EntryStatus::Conflict
    );
}

fn copy_tree(source: &Path, target: &Path) {
    fs::create_dir(target).unwrap();
    for item in fs::read_dir(source).unwrap() {
        let item = item.unwrap();
        let source_member = item.path();
        let target_member = target.join(item.file_name());
        let file_type = item.file_type().unwrap();
        if file_type.is_dir() {
            copy_tree(&source_member, &target_member);
        } else if file_type.is_file() {
            fs::copy(source_member, target_member).unwrap();
        } else {
            panic!("test fixture unexpectedly contains a reparse or special member");
        }
    }
}
