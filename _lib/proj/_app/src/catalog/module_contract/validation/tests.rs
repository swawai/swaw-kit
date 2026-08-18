use std::path::Path;

use serde_json::json;

use super::{MAX_PROVISIONS, MAX_REQUIREMENTS, ModuleManifest, validate_manifest};

#[test]
fn dependency_and_export_sets_share_the_provider_state_bound() {
    let requirements = (0..=MAX_REQUIREMENTS)
        .map(|index| {
            json!({
                "provider": format!("swaw/provider-{index}"),
                "export": "fixture",
                "contract": "fixture/v1"
            })
        })
        .collect::<Vec<_>>();
    let manifest: ModuleManifest = serde_json::from_value(json!({
        "schema": "swawkit.command-module/v8",
        "requires": requirements
    }))
    .unwrap();
    assert!(
        validate_manifest(&manifest, Path::new("requirements/swawkit.module.json"))
            .unwrap_err()
            .to_string()
            .contains("cannot contain more than 64 items")
    );

    let provisions = (0..=MAX_PROVISIONS)
        .map(|index| json!({"id": format!("export-{index}"), "contract": "fixture/v1"}))
        .collect::<Vec<_>>();
    let manifest: ModuleManifest = serde_json::from_value(json!({
        "schema": "swawkit.command-module/v8",
        "provides": provisions
    }))
    .unwrap();
    assert!(
        validate_manifest(&manifest, Path::new("provisions/swawkit.module.json"))
            .unwrap_err()
            .to_string()
            .contains("cannot contain more than 64 items")
    );
}
