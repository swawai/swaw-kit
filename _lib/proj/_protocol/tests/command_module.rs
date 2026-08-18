use swawkit_proj_protocol::parse_command_module;

const VALID_FULL: &[u8] = include_bytes!("fixtures/command-module/valid-full.json");
const INVALID_FACET: &[u8] = include_bytes!("fixtures/command-module/invalid-facet.json");
const INVALID_SUBJECT_KIND: &[u8] =
    include_bytes!("fixtures/command-module/invalid-subject-kind.json");

#[test]
fn shared_full_manifest_is_valid() {
    let manifest = parse_command_module(VALID_FULL).expect("valid shared v9 fixture");
    assert_eq!(manifest.facets.len(), 1);
    assert_eq!(manifest.subject_kinds.len(), 1);
}

#[test]
fn shared_invalid_ui_declarations_fail_closed() {
    for fixture in [INVALID_FACET, INVALID_SUBJECT_KIND] {
        assert!(parse_command_module(fixture).is_err());
    }
}

#[test]
fn obsolete_schema_has_no_fallback() {
    let bytes = br#"{"schema":"swawkit.command-module/v8"}"#;
    let error = parse_command_module(bytes).expect_err("v8 must fail");
    assert!(
        error
            .to_string()
            .contains("expected 'swawkit.command-module/v9'")
    );
}
