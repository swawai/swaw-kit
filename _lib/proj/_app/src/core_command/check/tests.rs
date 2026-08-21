use std::path::{Path, PathBuf};

use super::*;
use crate::catalog::{CATALOG_PROTOCOL, CommandNode};
use crate::command_check::{COMMAND_CHECK_PROTOCOL, CheckedCommand, DependencyChecker};

#[test]
fn read_only_dispatch_accepts_only_the_registered_check_addresses() {
    assert!(is_invocation(&argv(&[".check"])));
    assert!(is_invocation(&argv(&[".check/dir/exists"])));
    assert!(!is_invocation(&argv(&[".check/unknown"])));
}

#[test]
fn text_report_has_stable_sections() {
    let document = CommandCheckDocument {
        protocol: COMMAND_CHECK_PROTOCOL,
        command: CheckedCommand {
            address: ".tool".to_owned(),
            space: CommandSpace::System,
            namespace: None,
            runnable: true,
            adapter: Some("exe".to_owned()),
            diagnostic: None,
        },
        dependencies: Vec::new(),
        ready: true,
    };
    let output = render_text(&document, "fixture");
    assert!(output.contains("Command: .tool"));
    assert!(output.contains("Ready: yes"));
    assert!(output.contains("Dependencies:\n  none declared"));
    assert!(!output.contains("Guards:"));
    assert!(!output.contains("Publications:"));
}

#[test]
fn text_report_prints_the_structured_checker_invocation() {
    let document = CommandCheckDocument {
        protocol: COMMAND_CHECK_PROTOCOL,
        command: CheckedCommand {
            address: ".consumer".to_owned(),
            space: CommandSpace::System,
            namespace: None,
            runnable: true,
            adapter: Some("exe".to_owned()),
            diagnostic: None,
        },
        dependencies: vec![DependencyCheck {
            provider: ".dev/setup".to_owned(),
            export: "environment".to_owned(),
            ready: false,
            status: "state-missing".to_owned(),
            message: None,
            checker: Some(DependencyChecker {
                address: ".dev/setup/check".to_owned(),
                space: CommandSpace::System,
                namespace: None,
                arguments: vec!["environment".to_owned()],
            }),
            dependencies: Vec::new(),
        }],
        ready: false,
    };

    let output = render_text(&document, "proj1");

    assert!(output.contains("Check: proj1 .dev/setup/check environment"));
}

#[test]
fn ready_and_blocked_checks_are_legal_outcomes() {
    let context = context();
    let ready = snapshot(true);
    let outcome = execute(
        &ready,
        &argv(&[".check", ".target", "--json"]),
        &context,
        Path::new("unused-data-root"),
    )
    .unwrap()
    .unwrap();
    assert_eq!(outcome.exit_code, 0);
    assert!(outcome.stdout.contains("\"ready\": true"));
    assert!(outcome.stdout.ends_with("\n"));

    let blocked = snapshot(false);
    let outcome = execute(
        &blocked,
        &argv(&[".check", ".target"]),
        &context,
        Path::new("unused-data-root"),
    )
    .unwrap()
    .unwrap();
    assert_eq!(outcome.exit_code, 1);
    assert_eq!(
        outcome.stdout,
        "Command: .target\nReady: no\nRunnable: no\nAdapter: exe\nDiagnostic: not ready\n\nDependencies:\n  none declared\n"
    );
}

#[test]
fn malformed_invocation_is_a_typed_argument_error() {
    let error = execute(
        &snapshot(true),
        &argv(&[".check"]),
        &context(),
        Path::new("unused-data-root"),
    )
    .unwrap_err();
    assert!(matches!(error, CoreCommandError::Arguments { .. }));
    assert_eq!(
        error.to_string(),
        "usage: .check <command-address> [--json]"
    );
}

fn argv(values: &[&str]) -> Vec<OsString> {
    values.iter().map(OsString::from).collect()
}

fn snapshot(target_runnable: bool) -> CatalogSnapshot {
    CatalogSnapshot {
        protocol: CATALOG_PROTOCOL,
        entry_name: "fixture".to_owned(),
        language: "en",
        commands: vec![
            command(".check", true, Some("core"), Some("meta.check")),
            command(".target", target_runnable, Some("exe"), None),
        ],
    }
}

fn command(
    address: &str,
    runnable: bool,
    adapter: Option<&str>,
    handler: Option<&str>,
) -> CommandNode {
    CommandNode {
        address: address.to_owned(),
        space: CommandSpace::System,
        namespace: None,
        path: vec![address.trim_start_matches('.').to_owned()],
        parent: None,
        alias_of: None,
        runnable,
        entry: None,
        adapter: adapter.map(str::to_owned),
        handler: handler.map(str::to_owned),
        product: None,
        requirements: Vec::new(),
        provisions: Vec::new(),
        delegate_owner: None,
        declares_native: false,
        declared_facets: Vec::new(),
        declared_resource_kinds: Vec::new(),
        help: None,
        resource_kinds: Vec::new(),
        facets: Vec::new(),
        diagnostic: (!runnable).then(|| "not ready".to_owned()),
        authored_resource: true,
        help_diagnostic: None,
        directory: PathBuf::new(),
        executor_directory: PathBuf::new(),
        native_owner: None,
    }
}

fn context() -> EntryContext {
    EntryContext {
        swawkit_home: PathBuf::from("unused-home"),
        data_root: PathBuf::from("unused-data-root"),
        runtime_root: PathBuf::from("unused-runtime"),
        entry_file: PathBuf::from("unused-entry.exe"),
        entry_name: "fixture".to_owned(),
        invocation_directory: PathBuf::from("unused-project"),
        product_executable: PathBuf::from("unused-core.exe"),
        release_id: "unused-release".to_owned(),
    }
}
