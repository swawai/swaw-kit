use std::path::PathBuf;

use swawkit_proj_protocol::{
    FacetExecutionManifest, FacetRequirementsManifest, FacetRoute, ResourceExportsManifest,
    ResourceFacetKind, ResourceFacetPresentation, ResourceKindManifest, ResourceRoute,
    WebViewSource,
};
#[cfg(test)]
use swawkit_proj_protocol::{
    ResourceIdentity, ResourceList, ResourceListing, WebViewBundle, resolve_web_view,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct ResourceDiagnostic {
    pub(super) path: PathBuf,
    pub(super) message: String,
}

#[derive(Debug, Clone)]
pub(super) struct LoadedResource {
    pub(super) route: ResourceRoute,
    pub(super) selector: String,
    pub(super) kind: String,
    pub(super) directory: PathBuf,
    pub(super) exports: Option<ResourceExportsManifest>,
    pub(super) facets: Vec<LoadedFacet>,
}

#[derive(Debug, Clone)]
pub(super) struct LoadedFacet {
    pub(super) route: FacetRoute,
    pub(super) kind: ResourceFacetKind,
    pub(super) presentation: Option<ResourceFacetPresentation>,
    pub(super) directory: PathBuf,
    pub(super) local_entry: Option<String>,
    pub(super) execution: Option<FacetExecutionManifest>,
    pub(super) requirements: Option<FacetRequirementsManifest>,
    pub(super) view: Option<WebViewSource>,
    pub(super) resource_kind: Option<ResourceKindManifest>,
    pub(super) resources: Vec<LoadedResource>,
    pub(super) templates: Vec<FacetTemplate>,
}

#[derive(Debug, Clone)]
pub(super) struct FacetTemplate {
    pub(super) id: String,
    pub(super) kind: ResourceFacetKind,
    pub(super) presentation: Option<ResourceFacetPresentation>,
    pub(super) directory: PathBuf,
    pub(super) local_entry: Option<String>,
    pub(super) execution: Option<FacetExecutionManifest>,
    pub(super) requirements: Option<FacetRequirementsManifest>,
    pub(super) view: Option<WebViewSource>,
}

#[derive(Debug)]
pub(super) struct ResourceLoad {
    pub(super) resource: Option<LoadedResource>,
    pub(super) diagnostics: Vec<ResourceDiagnostic>,
}

#[cfg(test)]
impl LoadedFacet {
    pub(super) fn resource_list(&self) -> Result<ResourceList, String> {
        if self.kind != ResourceFacetKind::Collection {
            return Err(format!(
                "Facet '{}' does not produce a Resource List",
                self.route
            ));
        }
        resource_list(self.route.clone(), &self.resources)
    }

    pub(super) fn resolve_web_view(&self, list: ResourceList) -> Result<WebViewBundle, String> {
        let source = self
            .view
            .clone()
            .ok_or_else(|| format!("Facet '{}' has no Web View", self.route))?;
        resolve_web_view(source, self.route.clone(), list).map_err(|error| error.to_string())
    }
}

#[cfg(test)]
fn resource_list(source: FacetRoute, resources: &[LoadedResource]) -> Result<ResourceList, String> {
    let items = resources
        .iter()
        .map(|resource| {
            ResourceListing::new(
                ResourceIdentity::static_resource(resource.route.clone())
                    .map_err(|error| error.to_string())?,
                resource.selector.clone(),
                resource.route.clone(),
                resource
                    .facets
                    .iter()
                    .map(|facet| facet.route.facet().to_owned())
                    .collect(),
                resource.selector.clone(),
                resource.kind.clone(),
            )
            .map_err(|error| error.to_string())
        })
        .collect::<Result<Vec<_>, _>>()?;
    ResourceList::new(source, items).map_err(|error| error.to_string())
}
