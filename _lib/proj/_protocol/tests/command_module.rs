use swawkit_proj_protocol::parse_command_module;

const VALID_FULL: &[u8] = include_bytes!("fixtures/command-module/valid-full.json");
const INVALID_FACET: &[u8] = include_bytes!("fixtures/command-module/invalid-facet.json");
const INVALID_SUBJECT_KIND: &[u8] =
    include_bytes!("fixtures/command-module/invalid-subject-kind.json");

#[test]
fn shared_full_manifest_is_valid() {
    let manifest = parse_command_module(VALID_FULL).expect("valid shared v12 fixture");
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
    let bytes = br#"{"schema":"swawkit.command-module/v11"}"#;
    let error = parse_command_module(bytes).expect_err("v11 must fail");
    assert!(
        error
            .to_string()
            .contains("expected 'swawkit.command-module/v12'")
    );
}

#[test]
fn generic_export_contract_fields_have_no_fallback() {
    for bytes in [
        br#"{"schema":"swawkit.command-module/v12","requires":[{"provider":".dev/setup","export":"environment","contract":"legacy/v1"}]}"#.as_slice(),
        br#"{"schema":"swawkit.command-module/v12","provides":[{"id":"environment","contract":"legacy/v1"}]}"#.as_slice(),
    ] {
        assert!(parse_command_module(bytes).is_err());
    }
}

#[test]
fn system_delegate_owner_is_a_structured_command_identity() {
    let manifest = br#"{
        "schema":"swawkit.command-module/v12",
        "execution":{
            "type":"delegate",
            "owner":{"type":"command","space":"system","address":".context"}
        }
    }"#;
    parse_command_module(manifest).expect("System delegate owner must be supported");

    for invalid in [
        br#"{"schema":"swawkit.command-module/v12","execution":{"type":"delegate","owner":{"type":"command","space":"system","namespace":"swaw","address":".context"}}}"#.as_slice(),
        br#"{"schema":"swawkit.command-module/v12","execution":{"type":"delegate","owner":{"type":"command","space":"module","namespace":"project","address":"swaw/context"}}}"#.as_slice(),
    ] {
        assert!(parse_command_module(invalid).is_err());
    }
}
