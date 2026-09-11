use swawkit_proj_protocol::{
    CommandIdentity, ResourceIdentity, ResourceList, ResourceListing, command_resource_route,
};

use crate::{
    catalog::{CommandNode, PlannedFacetRoute, PlannedResourceRoute},
    facet::{FacetKind, FacetResolver},
};

use super::{RouteResolutionError, RouteResolver};

impl RouteResolver<'_> {
    pub(super) fn resolve_resource_list(
        &self,
        plan: &PlannedFacetRoute,
    ) -> Result<ResourceList, RouteResolutionError> {
        if plan.facet.kind != FacetKind::Collection {
            return Err(RouteResolutionError::invalid(
                "Web Resource List requires a Collection Facet",
            ));
        }
        match &plan.facet.resolver {
            Some(FacetResolver::Catalog { relation }) if relation == "subcommands" => {
                self.resolve_catalog_list(plan)
            }
            Some(FacetResolver::Command { .. }) => {
                let document = self.resolve_declared_facet(&plan.facet)?;
                let resources = document.resource_list.ok_or_else(|| {
                    RouteResolutionError::internal(
                        "collection facet resolver returned the wrong document type",
                    )
                })?;
                self.validate_collection_for_plan(plan, &resources)?;
                Ok(resources)
            }
            _ => Err(RouteResolutionError::invalid(
                "Collection Facet has no supported Resource List resolver",
            )),
        }
    }

    fn resolve_catalog_list(
        &self,
        plan: &PlannedFacetRoute,
    ) -> Result<ResourceList, RouteResolutionError> {
        let PlannedResourceRoute::Command { address } = &plan.resource else {
            return Err(RouteResolutionError::invalid(
                "nested dynamic Resource collections are not supported",
            ));
        };
        let resources = self
            .catalog
            .commands
            .iter()
            .filter(|command| {
                command.parent.as_deref() == Some(address.as_str()) && command.alias_of.is_none()
            })
            .map(|command| self.catalog_listing(plan, command))
            .collect::<Result<Vec<_>, _>>()?;
        ResourceList::new(plan.route.clone(), resources)
            .map_err(|error| RouteResolutionError::internal(error.to_string()))
    }

    fn catalog_listing(
        &self,
        plan: &PlannedFacetRoute,
        command: &CommandNode,
    ) -> Result<ResourceListing, RouteResolutionError> {
        let selector = command
            .path
            .last()
            .ok_or_else(|| RouteResolutionError::internal("subcommand has no Resource selector"))?;
        let route = plan
            .route
            .resource()
            .child(plan.route.facet(), selector)
            .map_err(|error| RouteResolutionError::internal(error.to_string()))?;
        let identity = CommandIdentity::new(
            command.space,
            command.namespace.as_deref(),
            command.path.clone(),
        )
        .map_err(|error| RouteResolutionError::internal(error.to_string()))?;
        let expected = command_resource_route(&identity)
            .map_err(|error| RouteResolutionError::internal(error.to_string()))?;
        if route != expected {
            return Err(RouteResolutionError::internal(
                "Catalog subcommand identity disagrees with its Resource Route",
            ));
        }
        ResourceListing::new(
            ResourceIdentity::static_resource(expected)
                .map_err(|error| RouteResolutionError::internal(error.to_string()))?,
            selector.clone(),
            route,
            command
                .facets
                .iter()
                .map(|facet| facet.id.clone())
                .collect(),
            selector.clone(),
            command
                .help
                .as_ref()
                .map(|help| help.summary.clone())
                .unwrap_or_default(),
        )
        .map_err(|error| RouteResolutionError::internal(error.to_string()))
    }
}
