use std::fs;

use super::{CommandExecutor, Fixture, argv, write_json};

#[test]
fn dependency_readiness_stops_execution_before_journal_or_command_side_effects() {
    let fixture = Fixture::new();
    let provider = fixture.command(".provider", "exit 0");
    let consumer = fixture.command(
        ".consumer",
        "Set-Content (Join-Path $env:SWAWKIT_PROJ_DATA_ROOT 'consumer-ran.txt') 'ran'; exit 0",
    );
    declare_dependency(&provider, &consumer);
    let catalog = fixture.catalog();
    let context = fixture.context();

    let error = CommandExecutor::new(&context, &catalog)
        .execute_journaled(&argv(&[".consumer"]))
        .unwrap_err();

    assert!(
        error
            .to_string()
            .contains("command dependencies are not ready")
    );
    assert!(error.to_string().contains("state-missing"));
    assert!(!fixture.data_root.join("consumer-ran.txt").exists());
    assert!(
        !fixture
            .data_root
            .join("modules/system/consumer/_runs")
            .exists()
    );
}

#[test]
fn dependency_readiness_allows_a_matching_ready_publication() {
    let fixture = Fixture::new();
    let provider = fixture.command(".provider", "exit 0");
    let consumer = fixture.command(
        ".consumer",
        "Set-Content (Join-Path $env:SWAWKIT_PROJ_DATA_ROOT 'consumer-ran.txt') 'ran'; exit 0",
    );
    declare_dependency(&provider, &consumer);
    let provider_data = fixture.data_root.join("modules/system/provider");
    fs::create_dir_all(provider_data.join("export")).unwrap();
    write_json(
        &provider_data.join("_state.json"),
        &serde_json::json!({
            "schema": "swawkit.command-provider-state/v3",
            "status": "ready",
            "inputRevision": format!("sha256-{}", "a".repeat(64)),
            "token": "b".repeat(32)
        }),
    );
    let catalog = fixture.catalog();

    let exit_code = CommandExecutor::new(&fixture.context(), &catalog)
        .execute_journaled(&argv(&[".consumer"]))
        .unwrap();

    assert_eq!(exit_code, 0);
    assert!(fixture.data_root.join("consumer-ran.txt").exists());
}

#[test]
fn dependency_readiness_rejects_the_retired_provider_export_list() {
    let fixture = Fixture::new();
    let provider = fixture.command(".provider", "exit 0");
    let consumer = fixture.command(
        ".consumer",
        "Set-Content (Join-Path $env:SWAWKIT_PROJ_DATA_ROOT 'consumer-ran.txt') 'ran'; exit 0",
    );
    declare_dependency(&provider, &consumer);
    let provider_data = fixture.data_root.join("modules/system/provider");
    fs::create_dir_all(provider_data.join("export")).unwrap();
    write_json(
        &provider_data.join("_state.json"),
        &serde_json::json!({
            "schema": "swawkit.command-provider-state/v3",
            "status": "ready",
            "inputRevision": format!("sha256-{}", "a".repeat(64)),
            "token": "b".repeat(32),
            "exports": []
        }),
    );
    let catalog = fixture.catalog();

    let error = CommandExecutor::new(&fixture.context(), &catalog)
        .execute(&argv(&[".consumer"]))
        .unwrap_err();

    assert!(error.to_string().contains("shape is invalid"));
    assert!(!fixture.data_root.join("consumer-ran.txt").exists());
}

fn declare_dependency(provider: &std::path::Path, consumer: &std::path::Path) {
    write_json(
        &provider.join("swawkit.exports.json"),
        &serde_json::json!({
            "schema": "swawkit.resource-exports/v1",
            "exports": [{ "id": "fixture" }]
        }),
    );
    write_json(
        &consumer.join("execute/swawkit.requirements.json"),
        &serde_json::json!({
            "schema": "swawkit.facet-requirements/v1",
            "requirements": [{
                "provider": "$/system::provider",
                "export": "fixture"
            }]
        }),
    );
}
