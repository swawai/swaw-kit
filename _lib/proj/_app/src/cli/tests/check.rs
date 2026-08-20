use std::fs;

use super::super::*;
use super::{Fixture, argv, run};

#[test]
fn command_check_requires_an_explicitly_initialized_entry() {
    let fixture = Fixture::new();
    fixture.core_command(".check", "meta.check");
    fixture.command(".target", "run.exe", "fixture");

    let error = run(
        &fixture.context,
        &argv(&[".check", ".target", "--json"]),
        CommandProcessMode::InheritConsole,
    )
    .unwrap_err();

    assert!(error.to_string().contains("is not initialized"));
    assert!(!fixture.data_root().exists());
}

#[test]
fn command_check_fails_closed_for_a_legacy_data_root() {
    let fixture = Fixture::new();
    fixture.core_command(".check", "meta.check");
    fixture.command(".target", "run.exe", "fixture");
    fs::create_dir_all(fixture.data_root()).unwrap();
    fs::write(fixture.data_root().join("_entry.json"), b"legacy").unwrap();

    let error = run(
        &fixture.context,
        &argv(&[".check", ".target", "--json"]),
        CommandProcessMode::InheritConsole,
    )
    .unwrap_err();

    assert!(error.to_string().contains("explicit migration"));
    assert!(!fixture.data_root().join("entry.id").exists());
}

#[test]
fn command_check_uses_declared_provider_state_and_returns_a_machine_exit_code() {
    let fixture = Fixture::new();
    fixture.core_command(".check", "meta.check");
    let provider = fixture.command(".provider", "run.exe", "fixture");
    fs::write(
        provider.join("swawkit.module.json"),
        r#"{"schema":"swawkit.command-module/v11","provides":[{"id":"fixture","contract":"swawkit.fixture/v1"}]}"#,
    )
    .unwrap();
    let consumer = fixture.command(".consumer", "run.exe", "fixture");
    fs::write(
        consumer.join("swawkit.module.json"),
        r#"{"schema":"swawkit.command-module/v11","requires":[{"provider":".provider","export":"fixture","contract":"swawkit.fixture/v1"}]}"#,
    )
    .unwrap();
    fixture.bind();

    assert_eq!(
        run(
            &fixture.context,
            &argv(&[".check", ".provider", "--json"]),
            CommandProcessMode::InheritConsole,
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
        run(
            &fixture.context,
            &argv(&[".check", ".consumer", "--json"]),
            CommandProcessMode::InheritConsole,
        )
        .unwrap(),
        0
    );

    fs::remove_file(provider_data.join("_state.json")).unwrap();
    assert_eq!(
        run(
            &fixture.context,
            &argv(&[".check", ".consumer"]),
            CommandProcessMode::InheritConsole,
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
    let error = run(
        &fixture.context,
        &argv(&[".check", ".consumer", "--json", "extra"]),
        CommandProcessMode::InheritConsole,
    )
    .unwrap_err();
    assert_eq!(
        error.to_string(),
        "usage: .check <command-address> [--json]"
    );
}
