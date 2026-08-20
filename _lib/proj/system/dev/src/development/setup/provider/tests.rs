use super::*;
use std::fs;
use std::os::windows::fs::OpenOptionsExt;
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT: AtomicU64 = AtomicU64::new(0);

fn fixture() -> (PathBuf, String) {
    let data_root = std::env::temp_dir().join(format!(
        "swawkit-setup-provider-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    fs::create_dir_all(&data_root).unwrap();
    let input_revision = current_input_revision(&data_root).unwrap();
    (data_root, input_revision)
}

#[test]
fn start_and_complete_use_a_token_cas_without_holding_the_lock() {
    let (data_root, input) = fixture();
    let provider = SetupProvider::new(&data_root, input).unwrap();
    let attempt = provider.start().unwrap();
    let unavailable = provider.read().unwrap().unwrap();
    assert_eq!(unavailable.status, "unavailable");
    assert!(unavailable.exports.is_none());

    provider.complete(&attempt).unwrap();
    let ready = provider.read().unwrap().unwrap();
    assert_eq!(ready.status, "ready");
    assert_eq!(ready.exports, Some(expected_exports()));
    fs::remove_dir_all(data_root).unwrap();
}

#[test]
fn stale_attempt_and_changed_settings_are_rejected() {
    let (data_root, input) = fixture();
    let provider = SetupProvider::new(&data_root, &input).unwrap();
    let stale = provider.start().unwrap();
    let current = provider.start().unwrap();
    assert!(provider.complete(&stale).is_err());
    provider.complete(&current).unwrap();

    let attempt = provider.start().unwrap();
    crate::development::setup::settings::DevSettingsStore::new(&data_root)
        .update_setting(".dev/bun/version", "1.2.16".to_owned(), Some("missing"))
        .unwrap();
    assert!(provider.complete(&attempt).is_err());
    assert!(provider.start().is_err());
    fs::remove_dir_all(data_root).unwrap();
}

#[test]
fn ready_reader_rejects_noncanonical_state_documents() {
    let (data_root, input) = fixture();
    let provider = SetupProvider::new(&data_root, &input).unwrap();
    let attempt = provider.start().unwrap();
    provider.complete(&attempt).unwrap();
    assert_eq!(
        read_ready(&data_root, &input).unwrap().token(),
        attempt.token()
    );

    let path = data_root.join("modules/system/dev/setup/_state.json");
    fs::write(
        &path,
        format!(
            "{{\"schema\":\"{STATE_SCHEMA}\",\"status\":\"ready\",\"inputRevision\":\"{input}\",\"token\":\"{}\",\"exports\":[{{\"id\":\"{PRODUCER_EXPORT}\",\"contract\":\"{PRODUCER_CONTRACT}\"}}],\"extra\":\"value\"}}",
            attempt.token()
        ),
    )
    .unwrap();
    assert!(read_ready(&data_root, &input).is_err());
    fs::remove_dir_all(data_root).unwrap();
}

#[test]
fn legacy_layout_moves_once_before_current_state_is_created() {
    let (data_root, _) = fixture();
    let legacy = data_root.join("modules/kernel/.dev/setup");
    fs::create_dir_all(legacy.join("export")).unwrap();
    fs::write(legacy.join("export/sentinel"), "legacy").unwrap();

    migrate_legacy_layout(&data_root).unwrap();

    let current = data_root.join("modules/system/dev/setup");
    assert_eq!(
        fs::read_to_string(current.join("export/sentinel")).unwrap(),
        "legacy"
    );
    assert!(!legacy.exists());
    migrate_legacy_layout(&data_root).unwrap();
    fs::remove_dir_all(data_root).unwrap();
}

#[test]
fn migration_merges_only_a_precreated_command_journal_root() {
    let (data_root, _) = fixture();
    let legacy = data_root.join("modules/kernel/.dev/setup");
    let legacy_runs = legacy.join("_runs/legacy-run");
    let current = data_root.join("modules/system/dev/setup");
    let current_runs = current.join("_runs/current-run");
    fs::create_dir_all(&legacy_runs).unwrap();
    fs::create_dir_all(&current_runs).unwrap();
    fs::write(legacy.join("_state.json"), "legacy-state").unwrap();
    fs::write(legacy_runs.join("state"), "legacy-run").unwrap();
    fs::write(current_runs.join("state"), "current-run").unwrap();

    migrate_legacy_layout(&data_root).unwrap();

    assert_eq!(
        fs::read_to_string(current.join("_state.json")).unwrap(),
        "legacy-state"
    );
    assert!(current.join("_runs/legacy-run/state").is_file());
    assert!(current.join("_runs/current-run/state").is_file());
    assert!(!legacy.exists());
    fs::remove_dir_all(data_root).unwrap();
}

#[test]
fn migration_keeps_an_exclusively_owned_current_journal_in_place() {
    let (data_root, _) = fixture();
    let legacy = data_root.join("modules/kernel/.dev/setup");
    let legacy_runs = legacy.join("_runs/legacy-run");
    let current = data_root.join("modules/system/dev/setup");
    let current_runs = current.join("_runs/current-run");
    fs::create_dir_all(&legacy_runs).unwrap();
    fs::create_dir_all(&current_runs).unwrap();
    fs::write(legacy.join("_state.json"), "legacy-state").unwrap();
    fs::write(legacy_runs.join("state"), "legacy-run").unwrap();
    fs::write(current_runs.join("state"), "current-run").unwrap();

    let owner_path = current.join("_runs/.current-run.owner.lock");
    let owner = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .share_mode(0)
        .open(&owner_path)
        .unwrap();

    migrate_legacy_layout(&data_root).unwrap();

    drop(owner);
    assert_eq!(
        fs::read_to_string(current.join("_state.json")).unwrap(),
        "legacy-state"
    );
    assert!(current.join("_runs/legacy-run/state").is_file());
    assert!(current.join("_runs/current-run/state").is_file());
    assert!(owner_path.is_file());
    assert!(!legacy.exists());
    fs::remove_dir_all(data_root).unwrap();
}

#[test]
fn migration_detects_all_journal_conflicts_before_moving_provider_state() {
    let (data_root, _) = fixture();
    let legacy = data_root.join("modules/kernel/.dev/setup");
    let legacy_runs = legacy.join("_runs/same-run");
    let current = data_root.join("modules/system/dev/setup");
    let current_runs = current.join("_runs/same-run");
    fs::create_dir_all(&legacy_runs).unwrap();
    fs::create_dir_all(&current_runs).unwrap();
    fs::write(legacy.join("_state.json"), "legacy-state").unwrap();
    fs::write(legacy_runs.join("state"), "legacy-run").unwrap();
    fs::write(current_runs.join("state"), "current-run").unwrap();

    assert!(
        migrate_legacy_layout(&data_root)
            .unwrap_err()
            .contains("journal exists in both legacy and current state")
    );

    assert_eq!(
        fs::read_to_string(legacy.join("_state.json")).unwrap(),
        "legacy-state"
    );
    assert!(!current.join("_state.json").exists());
    assert_eq!(
        fs::read_to_string(legacy_runs.join("state")).unwrap(),
        "legacy-run"
    );
    assert_eq!(
        fs::read_to_string(current_runs.join("state")).unwrap(),
        "current-run"
    );
    fs::remove_dir_all(data_root).unwrap();
}

#[test]
fn migration_rejects_two_provider_states_instead_of_guessing() {
    let (data_root, _) = fixture();
    let legacy = data_root.join("modules/kernel/.dev/setup");
    let current = data_root.join("modules/system/dev/setup");
    fs::create_dir_all(&legacy).unwrap();
    fs::create_dir_all(&current).unwrap();
    fs::write(legacy.join("_state.json"), "legacy").unwrap();
    fs::write(current.join("_state.json"), "current").unwrap();

    assert!(
        migrate_legacy_layout(&data_root)
            .unwrap_err()
            .contains("legacy and current development setup state both exist")
    );
    fs::remove_dir_all(data_root).unwrap();
}
