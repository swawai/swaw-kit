use std::path::PathBuf;

use super::*;
use crate::catalog::{CATALOG_PROTOCOL, CommandNode};
use crate::resource_kind::ResourceKind;

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
fn global_run_timestamps_are_stable_utc_labels() {
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
        &PathBuf::from("unused-data-root"),
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
            requirements: Vec::new(),
            provisions: Vec::new(),
            delegate_owner: None,
            declares_native: false,
            declared_facets: Vec::new(),
            declared_resource_kinds: Vec::new(),
            help: None,
            resource_kinds: vec![ResourceKind {
                kind: RUN_KIND.to_owned(),
                source: swawkit_proj_protocol::FacetRoute::parse("$/system::runs/all").unwrap(),
                facets: Vec::new(),
            }],
            facets: Vec::new(),
            diagnostic: None,
            authored_resource: true,
            help_diagnostic: None,
            directory: PathBuf::new(),
            executor_directory: PathBuf::new(),
            native_owner: None,
        }],
    }
}
