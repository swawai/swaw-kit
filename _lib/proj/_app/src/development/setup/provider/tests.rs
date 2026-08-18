use super::*;
use std::fs;
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT: AtomicU64 = AtomicU64::new(0);

fn fixture() -> (PathBuf, String) {
    let data_root = std::env::temp_dir().join(format!(
        "swawkit-setup-provider-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    fs::create_dir_all(&data_root).unwrap();
    fs::write(data_root.join("_profile.json"), b"{\"revision\":1}").unwrap();
    let revision = profile_revision(&data_root.join("_profile.json")).unwrap();
    (data_root, revision)
}

#[test]
fn start_and_complete_use_a_token_cas_without_holding_the_lock() {
    let (data_root, profile_revision) = fixture();
    let input = format!("sha256-{}", "a".repeat(64));
    let provider = SetupProvider::new(&data_root, profile_revision, input).unwrap();
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
fn stale_attempt_is_rejected_and_profile_is_checked_only_at_start() {
    let (data_root, profile_revision) = fixture();
    let input = format!("sha256-{}", "b".repeat(64));
    let provider = SetupProvider::new(&data_root, profile_revision, input).unwrap();
    let stale = provider.start().unwrap();
    let current = provider.start().unwrap();
    assert!(provider.complete(&stale).is_err());
    provider.complete(&current).unwrap();

    let attempt = provider.start().unwrap();
    fs::write(data_root.join("_profile.json"), b"{\"revision\":2}").unwrap();
    provider.complete(&attempt).unwrap();
    assert!(provider.start().is_err());
    fs::remove_dir_all(data_root).unwrap();
}

#[test]
fn ready_reader_rejects_noncanonical_state_documents() {
    let (data_root, profile_revision) = fixture();
    let input = format!("sha256-{}", "c".repeat(64));
    let provider = SetupProvider::new(&data_root, profile_revision, &input).unwrap();
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
