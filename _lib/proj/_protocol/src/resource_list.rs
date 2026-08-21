use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use crate::{
    FacetRoute, ProtocolError, ProtocolResult, ResourceRoute,
    resource_route::{validate_facet_id, validate_resource_selector},
};

pub const RESOURCE_LIST_PROTOCOL: &str = "swawkit.resource-list/v2";
pub const MAX_RESOURCE_LIST_ITEMS: usize = 1024;
pub const MAX_RESOURCE_LISTING_FACETS: usize = 32;

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "lowercase", deny_unknown_fields)]
/// The stable identity of one Resource, independent from the route used to list it.
pub enum ResourceIdentity {
    /// A repository-authored Resource at its one canonical owning route.
    Static { route: ResourceRoute },
    /// A runtime Resource whose identity is scoped by its defining Resource Kind.
    Instance { kind: FacetRoute, id: String },
}

impl ResourceIdentity {
    pub fn static_resource(route: ResourceRoute) -> ProtocolResult<Self> {
        let identity = Self::Static { route };
        identity.validate()?;
        Ok(identity)
    }

    pub fn instance(kind: FacetRoute, id: impl Into<String>) -> ProtocolResult<Self> {
        let identity = Self::Instance {
            kind,
            id: id.into(),
        };
        identity.validate()?;
        Ok(identity)
    }

    pub fn validate(&self) -> ProtocolResult<()> {
        match self {
            Self::Static { route } => route.validate(),
            Self::Instance { kind, id } => {
                kind.validate()?;
                validate_resource_selector(id)
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ResourceListing {
    identity: ResourceIdentity,
    selector: String,
    route: ResourceRoute,
    facet_ids: Vec<String>,
    label: String,
    summary: String,
}

impl ResourceListing {
    pub fn new(
        identity: ResourceIdentity,
        selector: impl Into<String>,
        route: ResourceRoute,
        facet_ids: Vec<String>,
        label: impl Into<String>,
        summary: impl Into<String>,
    ) -> ProtocolResult<Self> {
        let listing = Self {
            identity,
            selector: selector.into(),
            route,
            facet_ids,
            label: label.into(),
            summary: summary.into(),
        };
        listing.validate()?;
        Ok(listing)
    }

    pub fn identity(&self) -> &ResourceIdentity {
        &self.identity
    }

    pub fn selector(&self) -> &str {
        &self.selector
    }

    pub fn route(&self) -> &ResourceRoute {
        &self.route
    }

    pub fn facet_ids(&self) -> &[String] {
        &self.facet_ids
    }

    pub fn label(&self) -> &str {
        &self.label
    }

    pub fn summary(&self) -> &str {
        &self.summary
    }

    fn validate(&self) -> ProtocolResult<()> {
        self.identity.validate()?;
        validate_resource_selector(&self.selector)?;
        self.route.validate()?;
        if self.facet_ids.len() > MAX_RESOURCE_LISTING_FACETS {
            return Err(ProtocolError::new(format!(
                "Resource listing cannot grant more than {MAX_RESOURCE_LISTING_FACETS} Facets"
            )));
        }
        let mut facet_ids = BTreeSet::new();
        for facet_id in &self.facet_ids {
            validate_facet_id(facet_id)?;
            if !facet_ids.insert(facet_id) {
                return Err(ProtocolError::new(
                    "Resource listing contains a duplicate Facet id",
                ));
            }
        }
        validate_text(&self.label, 128, false, "Resource label")?;
        validate_text(&self.summary, 500, true, "Resource summary")
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ResourceList {
    protocol: String,
    source: FacetRoute,
    resources: Vec<ResourceListing>,
}

impl ResourceList {
    pub fn new(source: FacetRoute, resources: Vec<ResourceListing>) -> ProtocolResult<Self> {
        let list = Self {
            protocol: RESOURCE_LIST_PROTOCOL.to_owned(),
            source,
            resources,
        };
        list.validate()?;
        Ok(list)
    }

    pub fn protocol(&self) -> &str {
        &self.protocol
    }

    pub fn source(&self) -> &FacetRoute {
        &self.source
    }

    pub fn resources(&self) -> &[ResourceListing] {
        &self.resources
    }

    pub fn select(&self, selector: &str) -> Option<&ResourceRoute> {
        self.resources
            .iter()
            .find(|resource| resource.selector == selector)
            .map(ResourceListing::route)
    }

    pub fn validate(&self) -> ProtocolResult<()> {
        if self.protocol != RESOURCE_LIST_PROTOCOL {
            return Err(ProtocolError::new(format!(
                "Resource List protocol must be {RESOURCE_LIST_PROTOCOL}"
            )));
        }
        self.source.validate()?;
        if self.resources.len() > MAX_RESOURCE_LIST_ITEMS {
            return Err(ProtocolError::new(format!(
                "Resource List cannot contain more than {MAX_RESOURCE_LIST_ITEMS} items"
            )));
        }

        let mut selectors = BTreeSet::new();
        let mut routes = BTreeSet::new();
        let mut identities = BTreeSet::new();
        for resource in &self.resources {
            resource.validate()?;
            let expected_route = self
                .source
                .resource()
                .child(self.source.facet(), resource.selector())?;
            if resource.route() != &expected_route {
                return Err(ProtocolError::new(
                    "Resource listing route must record selection through its source Facet",
                ));
            }
            if !selectors.insert(resource.selector()) {
                return Err(ProtocolError::new(
                    "Resource List contains a duplicate selector",
                ));
            }
            if !routes.insert(resource.route()) {
                return Err(ProtocolError::new(
                    "Resource List contains a duplicate Resource route",
                ));
            }
            if !identities.insert(resource.identity()) {
                return Err(ProtocolError::new(
                    "Resource List contains a duplicate Resource identity",
                ));
            }
        }
        Ok(())
    }
}

pub fn parse_resource_list(bytes: &[u8]) -> ProtocolResult<ResourceList> {
    let list: ResourceList = serde_json::from_slice(bytes)
        .map_err(|error| ProtocolError::new(format!("invalid Resource List JSON: {error}")))?;
    list.validate()?;
    Ok(list)
}

fn validate_text(
    value: &str,
    maximum: usize,
    allow_empty: bool,
    field: &str,
) -> ProtocolResult<()> {
    if (!allow_empty && value.is_empty())
        || value.trim() != value
        || value.chars().count() > maximum
    {
        Err(ProtocolError::new(format!(
            "{field} must contain {} to {maximum} trimmed characters",
            usize::from(!allow_empty)
        )))
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn resource(route: &str) -> ResourceRoute {
        ResourceRoute::parse(route).unwrap()
    }

    fn facet(route: &str) -> FacetRoute {
        FacetRoute::parse(route).unwrap()
    }

    #[test]
    fn one_identity_can_be_listed_through_distinct_routes_and_grants() {
        let identity = ResourceIdentity::instance(facet("$/system::runs/all"), "run-01").unwrap();
        let all_route = resource("$/system::runs/all::run-01");
        let command_route = resource("$/system::dev/runs::latest");
        let all = ResourceList::new(
            facet("$/system::runs/all"),
            vec![
                ResourceListing::new(
                    identity.clone(),
                    "run-01",
                    all_route.clone(),
                    vec!["overview".to_owned(), "open".to_owned()],
                    "Run 01",
                    "",
                )
                .unwrap(),
            ],
        )
        .unwrap();
        let command = ResourceList::new(
            facet("$/system::dev/runs"),
            vec![
                ResourceListing::new(
                    identity,
                    "latest",
                    command_route.clone(),
                    vec!["overview".to_owned()],
                    "Run 01",
                    "",
                )
                .unwrap(),
            ],
        )
        .unwrap();

        assert_eq!(all.select("run-01"), Some(&all_route));
        assert_eq!(command.select("latest"), Some(&command_route));
        assert_eq!(
            all.resources()[0].identity(),
            command.resources()[0].identity()
        );
        assert_ne!(
            all.resources()[0].facet_ids(),
            command.resources()[0].facet_ids()
        );
        assert_ne!(all.source(), command.source());
    }

    #[test]
    fn wire_names_resource_routes_instead_of_identity_refs() {
        let list = ResourceList::new(
            facet("$/system::dev/subcommands"),
            vec![
                ResourceListing::new(
                    ResourceIdentity::static_resource(resource("$/system::dev/subcommands::bun"))
                        .unwrap(),
                    "bun",
                    resource("$/system::dev/subcommands::bun"),
                    vec!["subcommands".to_owned()],
                    "Bun",
                    "",
                )
                .unwrap(),
            ],
        )
        .unwrap();
        let value = serde_json::to_value(list).unwrap();

        assert_eq!(value["resources"][0]["identity"]["type"], "static");
        assert!(value["resources"][0].get("route").is_some());
        assert!(value["resources"][0].get("ref").is_none());
    }

    #[test]
    fn rejects_duplicate_edges_and_extended_wire_data() {
        let route = resource("$/system::context/contexts::release-check");
        let item = ResourceListing::new(
            ResourceIdentity::instance(facet("$/system::context/contexts"), "release-check")
                .unwrap(),
            "release-check",
            route,
            vec!["show".to_owned()],
            "release-check",
            "",
        )
        .unwrap();
        assert!(
            ResourceList::new(
                facet("$/system::context/contexts"),
                vec![item.clone(), item],
            )
            .is_err()
        );

        let extended = br#"{
            "protocol":"swawkit.resource-list/v2",
            "source":{"resource":{"hops":[]},"facet":"contexts"},
            "resources":[],
            "legacy":true
        }"#;
        assert!(parse_resource_list(extended).is_err());
    }
}
