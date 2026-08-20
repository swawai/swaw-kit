use std::path::PathBuf;

use super::*;
use crate::catalog::{CATALOG_PROTOCOL, CommandNode};
use crate::subject_kind::SubjectKind;

#[test]
fn latest_selectors_are_explicit_and_bounded() {
    let one = render::parse_latest_selector("1").unwrap();
    assert_eq!((one.start, one.end), (1, 1));
    let range = render::parse_latest_selector("1..3").unwrap();
    assert_eq!((range.start, range.end), (1, 3));
    for invalid in ["0", "-1", "1,3", "3..1", "1..33", "1..2..3"] {
        assert!(render::parse_latest_selector(invalid).is_err(), "{invalid}");
    }
}

#[test]
fn global_run_subject_timestamps_are_stable_utc_labels() {
    assert_eq!(render::format_timestamp(0), "1970-01-01 00:00:00.000Z");
    assert_eq!(
        render::format_timestamp(1_787_027_678_901),
        "2026-08-18 04:34:38.901Z"
    );
}

#[test]
fn run_summary_preserves_the_public_separator_text() {
    assert_eq!(
        query::run_summary(".demo", "exited", "CLI", 1),
        ".demo · exited · CLI · 1 events"
    );
}

#[test]
fn empty_history_is_a_complete_stdout_outcome() {
    let outcome = execute(
        &snapshot(),
        &argv(&[".runs"]),
        &context(),
        &PathBuf::from("unused-data-root"),
        &EntryProfileState::Missing {
            path: PathBuf::from("unused-profile.json"),
        },
    )
    .unwrap()
    .unwrap();

    assert_eq!(outcome.exit_code, 0);
    assert_eq!(outcome.stdout, "Recent Runs:\n  none\n");
}

fn argv(values: &[&str]) -> Vec<OsString> {
    values.iter().map(OsString::from).collect()
}

fn snapshot() -> CatalogSnapshot {
    CatalogSnapshot {
        protocol: CATALOG_PROTOCOL,
        entry_name: "fixture".to_owned(),
        language: "en",
        commands: vec![CommandNode {
            address: RUNS_ADDRESS.to_owned(),
            space: CommandSpace::System,
            namespace: None,
            path: vec!["runs".to_owned()],
            parent: None,
            alias_of: None,
            runnable: true,
            entry: None,
            adapter: Some("core".to_owned()),
            handler: Some("meta.runs".to_owned()),
            product: None,
            module: None,
            help: None,
            subject_kinds: vec![SubjectKind {
                kind: RUN_KIND.to_owned(),
                facets: Vec::new(),
            }],
            facets: Vec::new(),
            view: None,
            diagnostic: None,
            help_diagnostic: None,
            directory: PathBuf::new(),
            native_owner: None,
        }],
    }
}

fn context() -> EntryContext {
    EntryContext {
        swawkit_home: PathBuf::from("unused-home"),
        data_root: PathBuf::from("unused-data-root"),
        runtime_root: PathBuf::from("unused-runtime"),
        entry_file: PathBuf::from("unused-entry.exe"),
        entry_name: "fixture".to_owned(),
        entry_id: crate::entry::EntryId::parse(&"a".repeat(64)).unwrap(),
        invocation_directory: PathBuf::from("unused-project"),
        product_executable: PathBuf::from("unused-core.exe"),
        release_id: "unused-release".to_owned(),
    }
}
