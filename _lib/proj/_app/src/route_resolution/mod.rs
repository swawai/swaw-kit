mod collection;
mod document;
mod resource_list;

use std::fmt;

use swawkit_proj_protocol::{
    FacetRoute, ResourceIdentity, ResourceList, ResourceRoute, WebColumnWidth, WebViewBundle,
    WebViewSource, resolve_web_view,
};

use crate::{
    catalog::{CatalogSnapshot, PlannedFacetRoute, PlannedResourceRoute, plan_facet_route},
    facet::{FacetKind, FacetResolver},
    runtime_service::{RuntimeQueryOutput, RuntimeService, RuntimeServiceError},
};

use collection::validate_collection_contract;

pub(crate) trait CommandQuery: Send + Sync {
    fn query(
        &self,
        address: &str,
        arguments: &[String],
    ) -> Result<RuntimeQueryOutput, RuntimeServiceError>;
}

impl CommandQuery for RuntimeService {
    fn query(
        &self,
        address: &str,
        arguments: &[String],
    ) -> Result<RuntimeQueryOutput, RuntimeServiceError> {
        RuntimeService::query(self, address, arguments)
    }
}

#[derive(Debug)]
pub(crate) enum RouteResolutionError {
    NotFound(String),
    Invalid(String),
    Internal(String),
    Runtime(RuntimeServiceError),
}

impl RouteResolutionError {
    pub(crate) fn not_found(message: impl Into<String>) -> Self {
        Self::NotFound(message.into())
    }

    pub(crate) fn invalid(message: impl Into<String>) -> Self {
        Self::Invalid(message.into())
    }

    pub(crate) fn internal(message: impl Into<String>) -> Self {
        Self::Internal(message.into())
    }
}

impl fmt::Display for RouteResolutionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotFound(message) | Self::Invalid(message) | Self::Internal(message) => {
                formatter.write_str(message)
            }
            Self::Runtime(error) => error.fmt(formatter),
        }
    }
}

pub(crate) struct ResolvedFacetDocument {
    pub(crate) value: serde_json::Value,
    resource_list: Option<ResourceList>,
}

pub(crate) struct ResolvedFacetInvocation {
    pub(crate) address: String,
    pub(crate) arguments: Vec<String>,
    pub(crate) accepts_tail: bool,
}

pub(crate) enum ResolvedFacetCall {
    Document(ResolvedFacetDocument),
    Invocation(ResolvedFacetInvocation),
}

pub(crate) struct RouteResolver<'a> {
    catalog: &'a CatalogSnapshot,
    query: &'a dyn CommandQuery,
}

impl<'a> RouteResolver<'a> {
    pub(crate) fn new(catalog: &'a CatalogSnapshot, query: &'a dyn CommandQuery) -> Self {
        Self { catalog, query }
    }

    pub(crate) fn resolve_document(
        &self,
        route: &FacetRoute,
    ) -> Result<ResolvedFacetDocument, RouteResolutionError> {
        match self.resolve_facet_call(route)? {
            ResolvedFacetCall::Document(document) => Ok(document),
            ResolvedFacetCall::Invocation(_) => Err(RouteResolutionError::invalid(
                "operation facets must run through the command execution boundary",
            )),
        }
    }

    pub(crate) fn resolve_facet_call(
        &self,
        route: &FacetRoute,
    ) -> Result<ResolvedFacetCall, RouteResolutionError> {
        let plan = self.plan(route)?;
        self.validate_selected_resource(&plan)?;
        match plan.facet.kind {
            FacetKind::Collection => {
                let resources = self.resolve_resource_list(&plan)?;
                let value = serde_json::to_value(&resources).map_err(|error| {
                    RouteResolutionError::internal(format!(
                        "cannot serialize resolved Resource List: {error}"
                    ))
                })?;
                Ok(ResolvedFacetCall::Document(ResolvedFacetDocument {
                    value,
                    resource_list: Some(resources),
                }))
            }
            FacetKind::Projection => self
                .resolve_declared_facet(&plan.facet)
                .map(ResolvedFacetCall::Document),
            FacetKind::Operation => {
                let Some(FacetResolver::Command {
                    address,
                    arguments,
                    accepts_tail,
                    ..
                }) = &plan.facet.resolver
                else {
                    return Err(RouteResolutionError::invalid(
                        "the requested operation Facet has no command resolver",
                    ));
                };
                self.require_invocation_target(address)?;
                Ok(ResolvedFacetCall::Invocation(ResolvedFacetInvocation {
                    address: address.clone(),
                    arguments: arguments.clone(),
                    accepts_tail: *accepts_tail,
                }))
            }
        }
    }

    pub(crate) fn resolve_view_bundle(
        &self,
        route: &FacetRoute,
    ) -> Result<WebViewBundle, RouteResolutionError> {
        let plan = self.plan(route)?;
        self.validate_selected_resource(&plan)?;
        let source = plan
            .facet
            .view
            .clone()
            .unwrap_or_else(|| WebViewSource::resource_list(WebColumnWidth::Normal));
        let resources = self.resolve_resource_list(&plan)?;
        resolve_web_view(source, route.clone(), resources)
            .map_err(|error| RouteResolutionError::internal(error.to_string()))
    }

    fn plan(&self, route: &FacetRoute) -> Result<PlannedFacetRoute, RouteResolutionError> {
        plan_facet_route(self.catalog, route).map_err(RouteResolutionError::not_found)
    }

    fn require_invocation_target(&self, address: &str) -> Result<(), RouteResolutionError> {
        let mut matches = self.catalog.commands.iter().filter(|command| {
            command.address == address && command.runnable && command.alias_of.is_none()
        });
        if matches.next().is_none() {
            return Err(RouteResolutionError::not_found(
                "Facet invocation target not found",
            ));
        }
        if matches.next().is_some() {
            return Err(RouteResolutionError::invalid(
                "Facet invocation target is ambiguous",
            ));
        }
        Ok(())
    }

    fn validate_collection_for_plan(
        &self,
        plan: &PlannedFacetRoute,
        resources: &ResourceList,
    ) -> Result<(), RouteResolutionError> {
        let PlannedResourceRoute::Command { .. } = &plan.resource else {
            return Err(RouteResolutionError::invalid(
                "nested dynamic Resource collections are not supported",
            ));
        };
        if resources.source() != &plan.route {
            return Err(RouteResolutionError::internal(
                "collection facet resolver returned a mismatched source route",
            ));
        }
        validate_collection_contract(self.catalog, resources, &plan.facet)
    }

    fn validate_selected_resource(
        &self,
        plan: &PlannedFacetRoute,
    ) -> Result<(), RouteResolutionError> {
        let PlannedResourceRoute::CollectionMember {
            collection: collection_facet,
            selector,
            resource_kind,
            ..
        } = &plan.resource
        else {
            return Ok(());
        };
        if plan.facet.kind == FacetKind::Collection {
            return Err(RouteResolutionError::invalid(
                "nested dynamic Resource collections are not supported",
            ));
        }
        let document = self.resolve_declared_facet(collection_facet)?;
        let resources = document.resource_list.ok_or_else(|| {
            RouteResolutionError::internal(
                "collection facet resolver returned the wrong document type",
            )
        })?;
        let (_, owner_hops) = plan
            .route
            .resource()
            .hops()
            .split_last()
            .expect("a dynamic Resource route contains its collection selection");
        let owner_route = ResourceRoute::new(owner_hops.to_vec())
            .map_err(|error| RouteResolutionError::internal(error.to_string()))?;
        let expected_source = FacetRoute::new(owner_route, collection_facet.id.clone())
            .map_err(|error| RouteResolutionError::internal(error.to_string()))?;
        if resources.source() != &expected_source {
            return Err(RouteResolutionError::internal(
                "collection facet resolver returned a mismatched source route",
            ));
        }
        validate_collection_contract(self.catalog, &resources, collection_facet)?;
        let resource = resources
            .resources()
            .iter()
            .find(|resource| {
                matches!(
                    resource.identity(),
                    ResourceIdentity::Instance { kind, id }
                        if kind == &resource_kind.source && id == selector
                ) && resource.selector() == selector
            })
            .ok_or_else(|| RouteResolutionError::not_found("Resource not found"))?;
        if !resource
            .facet_ids()
            .iter()
            .any(|candidate| candidate == plan.route.facet())
        {
            return Err(RouteResolutionError::not_found("Resource Facet not found"));
        }
        Ok(())
    }
}
