use crate::{catalog::CatalogSnapshot, facet::Facet, resource_kind::ResourceKind};
use swawkit_proj_protocol::{ResourceIdentity, ResourceList};

use super::RouteResolutionError;

pub(super) fn validate_collection_contract(
    catalog: &CatalogSnapshot,
    resources: &ResourceList,
    collection_facet: &Facet,
) -> Result<(), RouteResolutionError> {
    let resource_kind = collection_resource_kind(catalog, collection_facet)?;
    for resource in resources.resources() {
        let ResourceIdentity::Instance { kind, id } = resource.identity() else {
            return Err(RouteResolutionError::internal(
                "dynamic collection returned a static Resource identity",
            ));
        };
        if kind != &resource_kind.source
            || id != resource.selector()
            || resource
                .facet_ids()
                .iter()
                .any(|id| !resource_kind.facets.iter().any(|facet| &facet.id == id))
        {
            return Err(RouteResolutionError::internal(
                "facet resolver command returned an invalid Resource List",
            ));
        }
    }
    Ok(())
}

fn collection_resource_kind<'a>(
    catalog: &'a CatalogSnapshot,
    collection_facet: &Facet,
) -> Result<&'a ResourceKind, RouteResolutionError> {
    let reference = collection_facet
        .resource_kind
        .as_ref()
        .ok_or_else(|| RouteResolutionError::internal("collection Facet has no Resource Kind"))?;
    let mut matches = catalog
        .commands
        .iter()
        .flat_map(|command| command.resource_kinds.iter())
        .filter(|resource_kind| resource_kind.source == reference.source);
    let resource_kind = matches
        .next()
        .ok_or_else(|| RouteResolutionError::internal("collection Resource Kind is unavailable"))?;
    if matches.next().is_some() {
        return Err(RouteResolutionError::internal(
            "collection Resource Kind source is ambiguous",
        ));
    }
    Ok(resource_kind)
}
