use std::ffi::OsString;
use std::path::Path;

use serde_json::json;
use swawkit_proj_protocol::{FacetRoute, WEB_VIEW_BUNDLE_PROTOCOL, parse_web_view_bundle};

use super::*;
use crate::{
    route_resolution::CommandQuery,
    runtime_service::{RuntimeQueryOutput, RuntimeServiceError},
};

struct ContextCollectionQuery;

impl CommandQuery for ContextCollectionQuery {
    fn query(
        &self,
        address: &str,
        arguments: &[String],
    ) -> Result<RuntimeQueryOutput, RuntimeServiceError> {
        assert_eq!(address, ".context/list");
        assert_eq!(arguments, ["--json"]);
        Ok(RuntimeQueryOutput {
            stdout: json!({
                "protocol": "swawkit.resource-list/v2",
                "source": {
                    "resource": {"hops": [{"facet": "system", "selector": "context"}]},
                    "facet": "contexts"
                },
                "resources": [{
                    "identity": {
                        "type": "instance",
                        "kind": {
                            "resource": {"hops": [{"facet": "system", "selector": "context"}]},
                            "facet": "contexts"
                        },
                        "id": "release-check"
                    },
                    "selector": "release-check",
                    "route": {"hops": [
                        {"facet": "system", "selector": "context"},
                        {"facet": "contexts", "selector": "release-check"}
                    ]},
                    "facetIds": ["overview"],
                    "label": "release-check",
                    "summary": "Release verification"
                }]
            })
            .to_string(),
            exit_code: 0,
        })
    }
}

#[test]
fn source_resolves_one_dynamic_collection_into_a_closed_bundle() {
    let project = Path::new(env!("CARGO_MANIFEST_DIR"));
    let absent = project.join("target/view-source-absent-modules");
    let catalog =
        CatalogSnapshot::discover_roots(&project.join("../system"), &absent, &absent, "fixture")
            .expect("discover Resource Catalog");

    let outcome = execute_with_query(
        &catalog,
        &argv(&[".view/source", "$/system::context/contexts"]),
        &ContextCollectionQuery,
    )
    .unwrap()
    .expect("view command");
    let bundle = parse_web_view_bundle(outcome.stdout.as_bytes()).unwrap();

    assert_eq!(
        bundle.target(),
        &FacetRoute::parse("$/system::context/contexts").unwrap()
    );
    assert_eq!(bundle.resources()["facet-result"].resources().len(), 1);
    assert_eq!(
        bundle.resources()["facet-result"].resources()[0]
            .route()
            .canonical_route(),
        "$/system::context/contexts::release-check"
    );
    let value: serde_json::Value = serde_json::from_str(&outcome.stdout).unwrap();
    assert_eq!(value["protocol"], WEB_VIEW_BUNDLE_PROTOCOL);
}

#[test]
fn source_uses_the_platform_default_for_a_collection_without_author_view() {
    let project = Path::new(env!("CARGO_MANIFEST_DIR"));
    let absent = project.join("target/view-source-invalid-absent-modules");
    let catalog =
        CatalogSnapshot::discover_roots(&project.join("../system"), &absent, &absent, "fixture")
            .unwrap();

    let outcome = execute_with_query(
        &catalog,
        &argv(&[".view/source", "$/system::context/subcommands"]),
        &ContextCollectionQuery,
    )
    .unwrap()
    .expect("default view command");
    let bundle = parse_web_view_bundle(outcome.stdout.as_bytes()).unwrap();
    assert_eq!(
        bundle.view().width,
        swawkit_proj_protocol::WebColumnWidth::Normal
    );
    assert_eq!(bundle.resources()["facet-result"].resources().len(), 9);
}

fn argv(values: &[&str]) -> Vec<OsString> {
    values.iter().map(OsString::from).collect()
}
