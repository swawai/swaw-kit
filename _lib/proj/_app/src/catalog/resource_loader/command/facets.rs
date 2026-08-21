use swawkit_proj_protocol::{
    FacetExecution, FacetExecutionArgument, FacetExecutionBinding, FacetRoute, ResourceFacetKind,
    ResourceKindManifest, ResourceRoute,
};

use super::super::model::{FacetTemplate, LoadedFacet};
use crate::{
    catalog::declaration::{
        FacetArgumentDeclaration, FacetDeclaration, FacetResolverDeclaration,
        ResourceKindDeclaration,
    },
    entry_config::EntryLanguage,
    facet::{FacetKind, FacetRenderer},
};

pub(super) fn compile_authored_facets(
    facets: &[LoadedFacet],
    language: EntryLanguage,
    diagnostics: &mut Vec<String>,
) -> (Vec<FacetDeclaration>, Vec<ResourceKindDeclaration>) {
    let mut declarations = Vec::new();
    let mut resource_kinds = Vec::new();
    for facet in facets
        .iter()
        .filter(|facet| !matches!(facet.route.facet(), "execute" | "subcommands"))
    {
        if !supported_authored_facet(facet, diagnostics) {
            continue;
        }
        let Some(presentation) = facet.presentation.as_ref() else {
            diagnostics.push(format!(
                "authored Facet '{}' must declare presentation",
                facet.route
            ));
            continue;
        };
        let resource_kind = facet.resource_kind.as_ref().and_then(|kind| match kind {
            ResourceKindManifest::Definition(_) => Some(facet.route.clone()),
            ResourceKindManifest::Reference(reference) => {
                match FacetRoute::parse(&reference.reference) {
                    Ok(target) => Some(target),
                    Err(error) => {
                        diagnostics.push(format!(
                            "Resource Kind ref on '{}' is invalid: {error}",
                            facet.route
                        ));
                        None
                    }
                }
            }
        });
        let Some(resolver) = compile_invoke_resolver(facet, diagnostics) else {
            continue;
        };
        declarations.push(FacetDeclaration {
            id: facet.route.facet().to_owned(),
            kind: project_facet_kind(facet.kind),
            renderer: project_renderer(facet.kind),
            icon: presentation.icon.clone(),
            label: localized(&presentation.label, language),
            summary: localized(&presentation.summary, language),
            resource_kind: resource_kind.clone(),
            resolver: Some(resolver),
            view: facet.view.clone(),
        });
        match &facet.resource_kind {
            Some(ResourceKindManifest::Definition(kind)) => {
                let templates = facet
                    .templates
                    .iter()
                    .filter_map(|template| {
                        compile_template(template, &facet.route, language, diagnostics)
                    })
                    .collect();
                resource_kinds.push(ResourceKindDeclaration::Definition {
                    kind: kind.kind.clone(),
                    source: facet.route.clone(),
                    facets: templates,
                });
            }
            Some(ResourceKindManifest::Reference(_)) => {
                if let Some(target) = resource_kind {
                    resource_kinds.push(ResourceKindDeclaration::Reference {
                        source: facet.route.clone(),
                        target,
                    });
                }
            }
            None => {}
        }
    }
    (declarations, resource_kinds)
}

fn supported_authored_facet(facet: &LoadedFacet, diagnostics: &mut Vec<String>) -> bool {
    let mut supported = true;
    if facet.local_entry.is_some() {
        diagnostics.push(format!(
            "authored Facet '{}' cannot own a local run.* entry; invoke a Resource execute Facet instead",
            facet.route
        ));
        supported = false;
    }
    if facet.requirements.is_some() {
        diagnostics.push(format!(
            "authored Facet '{}' cannot own Requirements; the invoked Resource owns execution dependencies",
            facet.route
        ));
        supported = false;
    }
    if !facet.resources.is_empty() {
        diagnostics.push(format!(
            "authored Facet '{}' cannot own static Resources; only subcommands is a static Collection",
            facet.route
        ));
        supported = false;
    }
    supported
}

fn compile_template(
    template: &FacetTemplate,
    owner: &FacetRoute,
    language: EntryLanguage,
    diagnostics: &mut Vec<String>,
) -> Option<FacetDeclaration> {
    if template.local_entry.is_some() {
        diagnostics.push(format!(
            "Facet template '{}::{}' cannot own a local run.* entry; invoke a Resource execute Facet instead",
            owner, template.id
        ));
        return None;
    }
    if template.requirements.is_some() {
        diagnostics.push(format!(
            "Facet template '{}::{}' cannot own Requirements; the invoked Resource owns execution dependencies",
            owner, template.id
        ));
        return None;
    }
    let Some(presentation) = template.presentation.as_ref() else {
        diagnostics.push(format!(
            "Facet template '{}::{}' must declare presentation",
            owner, template.id
        ));
        return None;
    };
    let resolver = compile_template_resolver(template, diagnostics)?;
    Some(FacetDeclaration {
        id: template.id.clone(),
        kind: project_facet_kind(template.kind),
        renderer: project_renderer(template.kind),
        icon: presentation.icon.clone(),
        label: localized(&presentation.label, language),
        summary: localized(&presentation.summary, language),
        resource_kind: None,
        resolver: Some(resolver),
        view: template.view.clone(),
    })
}

fn compile_invoke_resolver(
    facet: &LoadedFacet,
    diagnostics: &mut Vec<String>,
) -> Option<FacetResolverDeclaration> {
    let Some(execution) = facet.execution.as_ref() else {
        diagnostics.push(format!(
            "authored Facet '{}' must declare invoke execution",
            facet.route
        ));
        return None;
    };
    compile_resolver(
        &facet.route.to_string(),
        &execution.implementation,
        Some(facet.route.resource()),
        false,
        diagnostics,
    )
}

fn compile_template_resolver(
    template: &FacetTemplate,
    diagnostics: &mut Vec<String>,
) -> Option<FacetResolverDeclaration> {
    let Some(execution) = template.execution.as_ref() else {
        diagnostics.push(format!(
            "Facet template '{}' must declare invoke execution",
            template.id
        ));
        return None;
    };
    compile_resolver(
        &template.id,
        &execution.implementation,
        None,
        true,
        diagnostics,
    )
}

fn compile_resolver(
    owner: &str,
    execution: &FacetExecution,
    resource_route: Option<&ResourceRoute>,
    allow_resource_selector: bool,
    diagnostics: &mut Vec<String>,
) -> Option<FacetResolverDeclaration> {
    let FacetExecution::Invoke {
        target,
        arguments,
        accepts_tail,
        confirmation,
        returns,
    } = execution
    else {
        diagnostics.push(format!(
            "authored Facet '{owner}' must use invoke execution"
        ));
        return None;
    };
    let target = FacetRoute::parse(target)
        .map_err(|error| error.to_string())
        .and_then(|target| super::super::command_identity_for_resource_route(target.resource()));
    let address = match target {
        Ok(identity) => identity.address(),
        Err(error) => {
            diagnostics.push(format!(
                "authored Facet '{owner}' target is invalid: {error}"
            ));
            return None;
        }
    };
    let mut projected_arguments = Vec::with_capacity(arguments.len());
    for argument in arguments {
        match argument {
            FacetExecutionArgument::Literal(value) => {
                projected_arguments.push(FacetArgumentDeclaration::Literal(value.clone()));
            }
            FacetExecutionArgument::Binding(binding) => match binding.bind {
                FacetExecutionBinding::ResourceSelector if allow_resource_selector => {
                    projected_arguments.push(FacetArgumentDeclaration::ResourceSelector);
                }
                FacetExecutionBinding::ResourceRoute => {
                    let Some(resource_route) = resource_route else {
                        diagnostics.push(format!(
                            "authored Facet '{owner}' cannot bind a Resource route in a dynamic template"
                        ));
                        return None;
                    };
                    projected_arguments.push(FacetArgumentDeclaration::Literal(
                        resource_route.to_string(),
                    ));
                }
                FacetExecutionBinding::ResourceSelector => {
                    diagnostics.push(format!(
                        "authored Facet '{owner}' cannot bind a Resource selector"
                    ));
                    return None;
                }
            },
        }
    }
    Some(FacetResolverDeclaration::Invoke {
        address,
        arguments: projected_arguments,
        accepts_tail: *accepts_tail,
        confirmation: confirmation.clone(),
        returns: returns.clone(),
    })
}

fn project_facet_kind(kind: ResourceFacetKind) -> FacetKind {
    match kind {
        ResourceFacetKind::Collection => FacetKind::Collection,
        ResourceFacetKind::Operation => FacetKind::Operation,
        ResourceFacetKind::Projection => FacetKind::Projection,
    }
}

fn project_renderer(kind: ResourceFacetKind) -> FacetRenderer {
    match kind {
        ResourceFacetKind::Collection => FacetRenderer::Collection,
        ResourceFacetKind::Operation => FacetRenderer::Run,
        ResourceFacetKind::Projection => FacetRenderer::Overview,
    }
}

fn localized(
    text: &swawkit_proj_protocol::ResourceLocalizedText,
    language: EntryLanguage,
) -> String {
    match language {
        EntryLanguage::ZhCn => text.zh_cn.clone(),
        EntryLanguage::En => text.en.clone(),
    }
}
