use std::fs;

use swawkit_proj::data_root::{ClaimApprovalError, DataRootClaim};

use super::super::*;
use super::{Fixture, argv};

#[test]
fn command_check_is_read_only_for_a_fresh_entry() {
    let fixture = Fixture::new();
    fixture.core_command(".check", "meta.check");
    fixture.command(".target", "run.exe", "fixture");
    let mut unexpected = |_claim: &DataRootClaim| -> Result<bool, ClaimApprovalError> {
        panic!("read-only command check must not invoke the DataRoot approver")
    };

    assert_eq!(
        run_with_approver(
            &fixture.context,
            &argv(&[".check", ".target", "--json"]),
            &mut unexpected,
        )
        .unwrap(),
        0
    );

    assert!(!fixture.root.join("data").exists());
    assert!(!fixture.data_root().join("_entry.json").exists());
    assert!(!fixture.root.join("data/_proj-entry.lock").exists());
}

#[test]
fn command_check_fails_closed_when_data_root_claim_is_required() {
    let fixture = Fixture::new();
    fixture.core_command(".check", "meta.check");
    fixture.command(".target", "run.exe", "fixture");
    fs::create_dir_all(fixture.data_root()).unwrap();
    let mut unexpected = |_claim: &DataRootClaim| -> Result<bool, ClaimApprovalError> {
        panic!("read-only command check must not invoke the DataRoot approver")
    };

    let error = run_with_approver(
        &fixture.context,
        &argv(&[".check", ".target", "--json"]),
        &mut unexpected,
    )
    .unwrap_err();

    assert!(
        error
            .to_string()
            .contains("DataRoot ownership claim is required")
    );
    assert!(error.to_string().contains(".entry/claim"));
    assert!(!fixture.data_root().join("_entry.json").exists());
    assert!(!fixture.root.join("data/_proj-entry.lock").exists());
}

#[test]
fn command_check_uses_declared_provider_state_and_returns_a_machine_exit_code() {
    let fixture = Fixture::new();
    fixture.core_command(".check", "meta.check");
    let provider = fixture.command(".provider", "run.exe", "fixture");
    fs::write(
        provider.join("swawkit.module.json"),
        r#"{"schema":"swawkit.command-module/v9","provides":[{"id":"fixture","contract":"swawkit.fixture/v1"}]}"#,
    )
    .unwrap();
    let consumer = fixture.command(".consumer", "run.exe", "fixture");
    fs::write(
        consumer.join("swawkit.module.json"),
        r#"{"schema":"swawkit.command-module/v9","requires":[{"provider":".provider","export":"fixture","contract":"swawkit.fixture/v1"}]}"#,
    )
    .unwrap();
    fixture.bind();
    let mut unexpected =
        |_claim: &DataRootClaim| Err(ClaimApprovalError::new("claim was not expected"));

    assert_eq!(
        run_with_approver(
            &fixture.context,
            &argv(&[".check", ".provider", "--json"]),
            &mut unexpected,
        )
        .unwrap(),
        0
    );

    let provider_data = fixture.data_root().join("modules/system/provider");
    fs::create_dir_all(provider_data.join("export")).unwrap();
    fs::write(provider_data.join("export/sentinel.txt"), "ready").unwrap();
    fs::write(
        provider_data.join("_state.json"),
        r#"{"schema":"swawkit.command-provider-state/v2","status":"ready","inputRevision":"sha256-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","exports":[{"id":"fixture","contract":"swawkit.fixture/v1"}]}"#,
    )
    .unwrap();

    assert_eq!(
        run_with_approver(
            &fixture.context,
            &argv(&[".check", ".consumer", "--json"]),
            &mut unexpected,
        )
        .unwrap(),
        0
    );

    fs::remove_file(provider_data.join("_state.json")).unwrap();
    assert_eq!(
        run_with_approver(
            &fixture.context,
            &argv(&[".check", ".consumer"]),
            &mut unexpected,
        )
        .unwrap(),
        1
    );
}

#[test]
fn command_check_rejects_ambiguous_arguments() {
    let fixture = Fixture::new();
    fixture.core_command(".check", "meta.check");
    fixture.bind();
    let mut unexpected =
        |_claim: &DataRootClaim| Err(ClaimApprovalError::new("claim was not expected"));
    let error = run_with_approver(
        &fixture.context,
        &argv(&[".check", ".consumer", "--json", "extra"]),
        &mut unexpected,
    )
    .unwrap_err();
    assert_eq!(
        error.to_string(),
        "usage: .check <command-address> [--json]"
    );
}
