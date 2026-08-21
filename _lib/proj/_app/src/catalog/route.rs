use swawkit_proj_protocol::{FacetRoute, ResourceRoute};

use crate::{
    facet::{Facet, FacetKind},
    resource_kind::ResourceKind,
};

use super::{CatalogSnapshot, CommandNode, CommandSpace};

#[derive(Debug, Clone)]
pub(crate) enum PlannedResourceRoute {
    Command {
        address: String,
    },
    CollectionMember {
        collection: Facet,
        selector: String,
        resource_kind: ResourceKind,
    },
}

#[derive(Debug, Clone)]
pub(crate) struct PlannedFacetRoute {
    pub(crate) route: FacetRoute,
    pub(crate) resource: PlannedResourceRoute,
    pub(crate) facet: Facet,
}

pub(crate) fn plan_facet_route(
    catalog: &CatalogSnapshot,
    route: &FacetRoute,
) -> Result<PlannedFacetRoute, String> {
    let resource = plan_resource(catalog, route.resource())?;
    let facet = match &resource {
        PlannedResourceRoute::Command { address, .. } => command(catalog, address)?
            .facets
            .iter()
            .find(|facet| facet.id == route.facet())
            .cloned()
            .ok_or_else(|| {
                format!(
                    "Resource '{}' does not expose Facet '{}'",
                    route.resource(),
                    route.facet()
                )
            })?,
        PlannedResourceRoute::CollectionMember {
            selector,
            resource_kind,
            ..
        } => resource_kind
            .instantiate(route.facet(), selector)?
            .ok_or_else(|| {
                format!(
                    "Resource kind '{}' does not define Facet '{}'",
                    resource_kind.kind,
                    route.facet()
                )
            })?,
    };
    Ok(PlannedFacetRoute {
        route: route.clone(),
        resource,
        facet,
    })
}

fn plan_resource(
    catalog: &CatalogSnapshot,
    route: &ResourceRoute,
) -> Result<PlannedResourceRoute, String> {
    if let Some(command) = command_for_resource_route(catalog, route) {
        return Ok(PlannedResourceRoute::Command {
            address: command.address.clone(),
        });
    }

    let (member, owner_hops) = route
        .hops()
        .split_last()
        .ok_or_else(|| format!("Resource Route '{route}' has no resolvable root"))?;
    let owner_route = ResourceRoute::new(owner_hops.to_vec()).map_err(|error| error.to_string())?;
    let owner = command_for_resource_route(catalog, &owner_route).ok_or_else(|| {
        format!(
            "Resource Route '{route}' attempts unsupported nested or unknown Resource traversal"
        )
    })?;
    let collection = owner
        .facets
        .iter()
        .find(|facet| facet.id == member.facet())
        .ok_or_else(|| {
            format!(
                "Resource '{}' does not expose Facet '{}'",
                owner_route,
                member.facet()
            )
        })?;
    if collection.kind != FacetKind::Collection {
        return Err(format!(
            "Facet '{}/{}' is not a Collection and cannot select Resource '{}'",
            owner_route,
            member.facet(),
            member.selector()
        ));
    }
    let kind = collection.resource_kind.as_ref().ok_or_else(|| {
        format!(
            "Collection Facet '{}/{}' does not produce dynamic Resources",
            owner_route,
            member.facet()
        )
    })?;
    let resource_kind = resource_kind_provider(catalog, &kind.source)?.clone();

    Ok(PlannedResourceRoute::CollectionMember {
        collection: collection.clone(),
        selector: member.selector().to_owned(),
        resource_kind,
    })
}

pub(crate) fn command_for_resource_route<'a>(
    catalog: &'a CatalogSnapshot,
    route: &ResourceRoute,
) -> Option<&'a CommandNode> {
    if route.hops().is_empty() {
        return catalog.commands.iter().find(|command| {
            command.space == CommandSpace::System
                && command.namespace.is_none()
                && command.path.is_empty()
        });
    }
    if route.hops().len() == 1 && route.hops()[0].facet() == "modules" {
        let namespace = route.hops()[0].selector();
        return catalog.commands.iter().find(|command| {
            command.space == CommandSpace::Module
                && command.namespace.as_deref() == Some(namespace)
                && command.path.is_empty()
        });
    }
    let identity = super::resource_loader::command_identity_for_resource_route(route).ok()?;
    catalog
        .commands
        .iter()
        .find(|command| command.address == identity.address() && command.alias_of.is_none())
}

fn command<'a>(catalog: &'a CatalogSnapshot, address: &str) -> Result<&'a CommandNode, String> {
    catalog
        .commands
        .iter()
        .find(|command| command.address == address)
        .ok_or_else(|| format!("Resource Route references missing Command Resource '{address}'"))
}

fn resource_kind_provider<'a>(
    catalog: &'a CatalogSnapshot,
    source: &FacetRoute,
) -> Result<&'a ResourceKind, String> {
    let mut matches = catalog
        .commands
        .iter()
        .flat_map(|command| command.resource_kinds.iter())
        .filter(|candidate| &candidate.source == source);
    let resource_kind = matches
        .next()
        .ok_or_else(|| format!("Resource Kind definition '{source}' is unavailable"))?;
    if matches.next().is_some() {
        return Err(format!("Resource Kind definition '{source}' is ambiguous"));
    }
    Ok(resource_kind)
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use crate::facet::FacetResolver;
    use swawkit_proj_protocol::{RouteTarget, parse_route};

    use super::*;

    fn catalog() -> CatalogSnapshot {
        let project = Path::new(env!("CARGO_MANIFEST_DIR"));
        let absent = project.join("target/route-planner-absent-modules");
        CatalogSnapshot::discover_roots(&project.join("../system"), &absent, &absent, "fixture")
            .expect("discover current Resource Catalog")
    }

    #[derive(Debug)]
    enum PlannedRoute {
        Resource(PlannedResourceRoute),
        Facet(PlannedFacetRoute),
    }

    fn plan_route(catalog: &CatalogSnapshot, route: &str) -> Result<PlannedRoute, String> {
        match parse_route(route).map_err(|error| error.to_string())? {
            RouteTarget::Resource(route) => {
                plan_resource(catalog, &route).map(PlannedRoute::Resource)
            }
            RouteTarget::Facet(route) => plan_facet_route(catalog, &route).map(PlannedRoute::Facet),
        }
    }

    #[test]
    fn plans_static_resources_and_facets_without_guessing_cli_syntax() {
        let catalog = catalog();
        let PlannedRoute::Resource(PlannedResourceRoute::Command { address, .. }) =
            plan_route(&catalog, "$/system::dev/subcommands::bun").unwrap()
        else {
            panic!("expected Command Resource")
        };
        assert_eq!(address, ".dev/bun");

        let PlannedRoute::Facet(plan) =
            plan_route(&catalog, "$/system::dev/subcommands::bun/execute").unwrap()
        else {
            panic!("expected Facet")
        };
        assert_eq!(plan.facet.id, "execute");
        assert!(matches!(
            plan.facet.resolver,
            Some(FacetResolver::Command { ref address, .. }) if address == ".dev/bun"
        ));
    }

    #[test]
    fn plans_dynamic_members_through_the_selected_collection_and_kind_provider() {
        let catalog = catalog();
        let PlannedRoute::Facet(plan) = plan_route(
            &catalog,
            "$/system::context/contexts::release-check/overview",
        )
        .unwrap() else {
            panic!("expected dynamic Facet")
        };
        let PlannedResourceRoute::CollectionMember {
            selector,
            resource_kind,
            ..
        } = plan.resource
        else {
            panic!("expected Collection member")
        };
        assert_eq!(selector, "release-check");
        assert_eq!(resource_kind.kind, "context");
        assert_eq!(plan.facet.id, "overview");
    }

    #[test]
    fn a_cross_provider_collection_keeps_local_route_and_definition_source_distinct() {
        let catalog = catalog();
        let PlannedRoute::Facet(plan) = plan_route(
            &catalog,
            "$/system::dev/subcommands::bun/runs::20260821-01/overview",
        )
        .unwrap() else {
            panic!("expected Run Facet")
        };
        let PlannedResourceRoute::CollectionMember { collection, .. } = plan.resource else {
            panic!("expected Run member")
        };
        assert_eq!(collection.id, "runs");
        assert_eq!(
            collection
                .resource_kind
                .as_ref()
                .expect("Run Resource Kind")
                .source
                .canonical_route(),
            "$/system::runs/all"
        );
    }

    #[test]
    fn rejects_non_collection_selection_unknown_facets_and_nested_dynamic_resources() {
        let catalog = catalog();
        for route in [
            "$/system::dev/execute::bun",
            "$/system::dev/missing",
            "$/system::context/contexts::release-check/missing",
            "$/system::context/contexts::release-check/links::nested/overview",
        ] {
            assert!(plan_route(&catalog, route).is_err(), "{route}");
        }
    }
}
