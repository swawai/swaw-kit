use crate::{catalog::CatalogSnapshot, command::CommandExecutor, command_check};

use super::TempFixture;

fn command(fixture: &TempFixture, path: &str) {
    fixture.write(
        &format!("system/{path}/swawkit.resource.json"),
        r#"{"schema":"swawkit.resource/v1","kind":"command"}"#,
    );
    fixture.write(
        &format!("system/{path}/execute/swawkit.facet.json"),
        r#"{"schema":"swawkit.facet/v1","kind":"operation"}"#,
    );
    fixture.write(&format!("system/{path}/execute/run.cmd"), "@exit /b 0");
}

fn catalog(fixture: &TempFixture) -> CatalogSnapshot {
    CatalogSnapshot::discover_roots(
        &fixture.path("system"),
        &fixture.path("absent"),
        &fixture.path("absent"),
        "fixture",
    )
    .unwrap()
}

fn requirements(provider: &str) -> String {
    format!(
        r#"{{"schema":"swawkit.facet-requirements/v1","requirements":[{{"provider":"{provider}","export":"tool"}}]}}"#
    )
}

#[test]
fn invalid_requirements_block_execution_without_hiding_other_commands() {
    for (document, diagnostic) in [
        ("{broken json".to_owned(), "invalid Facet Requirements JSON"),
        (
            r#"{"schema":"unsupported","requirements":[]}"#.to_owned(),
            "schema",
        ),
        (
            requirements("$/system::provider/items::instance"),
            "not a backing Command Resource",
        ),
    ] {
        let fixture = TempFixture::new();
        command(&fixture, "target");
        command(&fixture, "sibling");
        fixture.write(
            "system/target/subcommands/swawkit.facet.json",
            r#"{"schema":"swawkit.facet/v1","kind":"collection"}"#,
        );
        command(&fixture, "target/subcommands/child");
        fixture.write("system/target/execute/swawkit.requirements.json", &document);

        let catalog = catalog(&fixture);
        let check = command_check::inspect(&fixture.root, "fixture", &catalog, ".target").unwrap();
        assert!(!check.ready);
        assert!(!check.command.runnable);
        assert!(
            check
                .command
                .diagnostic
                .as_deref()
                .unwrap()
                .contains(diagnostic)
        );
        let error =
            CommandExecutor::validate_invocation(&catalog, &[".target".into()]).unwrap_err();
        assert!(error.to_string().contains(diagnostic), "{error}");
        for address in [".sibling", ".target/child"] {
            assert!(CommandExecutor::validate_invocation(&catalog, &[address.into()]).is_ok());
        }
    }
}

#[test]
fn unreadable_requirements_are_not_treated_as_absent() {
    let fixture = TempFixture::new();
    command(&fixture, "target");
    // A directory at the declaration path cannot be read as a protocol file.
    std::fs::create_dir(fixture.path("system/target/execute/swawkit.requirements.json")).unwrap();
    let catalog = catalog(&fixture);
    let check = command_check::inspect(&fixture.root, "fixture", &catalog, ".target").unwrap();
    assert!(!check.ready);
    assert!(
        check
            .command
            .diagnostic
            .as_deref()
            .unwrap()
            .contains("plain file")
    );
    assert!(CommandExecutor::validate_invocation(&catalog, &[".target".into()]).is_err());
}

#[test]
fn absent_requirements_allow_execution_and_valid_requirements_remain_enforced() {
    let fixture = TempFixture::new();
    command(&fixture, "target");
    let check =
        command_check::inspect(&fixture.root, "fixture", &catalog(&fixture), ".target").unwrap();
    assert!(check.ready);
    assert!(check.command.diagnostic.is_none());
    assert!(check.dependencies.is_empty());

    fixture.write(
        "system/target/execute/swawkit.requirements.json",
        &requirements("$/system::missing"),
    );
    let check =
        command_check::inspect(&fixture.root, "fixture", &catalog(&fixture), ".target").unwrap();
    assert!(!check.ready);
    assert!(check.command.runnable);
    assert!(check.command.diagnostic.is_none());
    assert_eq!(check.dependencies.len(), 1);
    assert_eq!(check.dependencies[0].status, "provider-missing");
}
