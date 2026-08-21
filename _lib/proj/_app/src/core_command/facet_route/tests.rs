use std::ffi::OsString;
use std::path::{Path, PathBuf};

use serde_json::json;

use super::*;
use crate::runtime_service::{RuntimeQueryOutput, RuntimeServiceError};

struct NoQuery;

impl CommandQuery for NoQuery {
    fn query(
        &self,
        address: &str,
        arguments: &[String],
    ) -> Result<RuntimeQueryOutput, RuntimeServiceError> {
        panic!("unexpected query: {address} {arguments:?}")
    }
}

struct ContextQuery {
    grants: Vec<&'static str>,
}

impl CommandQuery for ContextQuery {
    fn query(
        &self,
        address: &str,
        arguments: &[String],
    ) -> Result<RuntimeQueryOutput, RuntimeServiceError> {
        let document = match (address, arguments) {
            (".context/list", [format]) if format == "--json" => json!({
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
                    "facetIds": self.grants,
                    "label": "release-check",
                    "summary": "Release verification"
                }]
            }),
            (".context/show", [id]) if id == "release-check" => json!({
                "schema": "swawkit.context/v2",
                "id": "release-check",
                "commands": [],
                "notes": [],
                "prompt": ""
            }),
            _ => panic!("unexpected query: {address} {arguments:?}"),
        };
        Ok(RuntimeQueryOutput {
            stdout: document.to_string(),
            exit_code: 0,
        })
    }
}

fn catalog() -> CatalogSnapshot {
    let project = Path::new(env!("CARGO_MANIFEST_DIR"));
    let absent: PathBuf = project.join("target/facet-route-absent-modules");
    CatalogSnapshot::discover_roots(&project.join("../system"), &absent, &absent, "fixture")
        .expect("discover Resource Catalog")
}

#[test]
fn static_execute_route_becomes_one_backing_invocation_with_its_tail() {
    let resolution = resolve_with_query(
        &catalog(),
        &argv(&["$/system::dev/subcommands::bun/execute", "--revision"]),
        &NoQuery,
    )
    .unwrap()
    .expect("Facet Route");
    assert_eq!(
        resolution,
        CliFacetRouteResolution::Invocation(argv(&[".dev/bun", "--revision"]))
    );
}

#[test]
fn catalog_collection_route_returns_the_resource_list_document() {
    let resolution =
        resolve_with_query(&catalog(), &argv(&["$/system::dev/subcommands"]), &NoQuery)
            .unwrap()
            .expect("Facet Route");
    let CliFacetRouteResolution::Document(outcome) = resolution else {
        panic!("expected document")
    };
    let document: serde_json::Value = serde_json::from_str(&outcome.stdout).unwrap();
    assert_eq!(document["protocol"], "swawkit.resource-list/v2");
    assert_eq!(document["resources"].as_array().unwrap().len(), 9);
}

#[test]
fn dynamic_projection_is_membership_checked_and_resolved_as_a_document() {
    let resolution = resolve_with_query(
        &catalog(),
        &argv(&["$/system::context/contexts::release-check/overview"]),
        &ContextQuery {
            grants: vec!["overview"],
        },
    )
    .unwrap()
    .expect("Facet Route");
    let CliFacetRouteResolution::Document(outcome) = resolution else {
        panic!("expected document")
    };
    let document: serde_json::Value = serde_json::from_str(&outcome.stdout).unwrap();
    assert_eq!(document["schema"], "swawkit.context/v2");
    assert_eq!(document["id"], "release-check");
}

#[test]
fn dynamic_operation_uses_only_the_local_grant_and_bound_selector() {
    let resolution = resolve_with_query(
        &catalog(),
        &argv(&[
            "$/system::context/contexts::release-check/add",
            ".dev/status",
        ]),
        &ContextQuery {
            grants: vec!["add"],
        },
    )
    .unwrap()
    .expect("Facet Route");
    assert_eq!(
        resolution,
        CliFacetRouteResolution::Invocation(argv(&[
            ".context/add",
            "release-check",
            ".dev/status",
        ]))
    );

    let denied = resolve_with_query(
        &catalog(),
        &argv(&["$/system::context/contexts::release-check/add"]),
        &ContextQuery {
            grants: vec!["overview"],
        },
    )
    .unwrap_err();
    assert!(denied.to_string().contains("Resource Facet not found"));
}

#[test]
fn command_addresses_are_not_guessed_as_facet_routes() {
    assert_eq!(
        resolve_with_query(&catalog(), &argv(&[".dev/bun"]), &NoQuery).unwrap(),
        None
    );
}

fn argv(values: &[&str]) -> Vec<OsString> {
    values.iter().map(OsString::from).collect()
}
