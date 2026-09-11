use swawkit_proj_protocol::ResourceFacetKind;

use super::super::model::LoadedFacet;
use super::ResourceCommandChild;
use crate::{
    catalog::declaration::{FacetDeclaration, FacetResolverDeclaration},
    entry_config::EntryLanguage,
    facet::{FacetKind, FacetRenderer},
};

pub(super) struct CompiledSubcommands {
    pub(super) children: Vec<ResourceCommandChild>,
    pub(super) declaration: Option<FacetDeclaration>,
}

impl Default for CompiledSubcommands {
    fn default() -> Self {
        Self {
            children: Vec::new(),
            declaration: None,
        }
    }
}

pub(super) fn compile_subcommands(
    facets: &[LoadedFacet],
    language: EntryLanguage,
    diagnostics: &mut Vec<String>,
) -> CompiledSubcommands {
    let Some(facet) = facets
        .iter()
        .find(|facet| facet.route.facet() == "subcommands")
    else {
        return CompiledSubcommands::default();
    };
    if facet.kind != ResourceFacetKind::Collection
        || facet.local_entry.is_some()
        || facet.execution.is_some()
        || facet.requirements.is_some()
        || facet.resource_kind.is_some()
        || !facet.templates.is_empty()
    {
        diagnostics.push(format!(
            "subcommands Facet '{}' must be a static Core Collection",
            facet.route
        ));
        return CompiledSubcommands::default();
    }
    let children = facet
        .resources
        .iter()
        .map(|resource| ResourceCommandChild {
            selector: resource.selector.clone(),
            directory: resource.directory.clone(),
        })
        .collect();
    let (label, summary) = match language {
        EntryLanguage::ZhCn => ("子命令", "浏览静态子命令"),
        EntryLanguage::En => ("Subcommands", "Browse static subcommands"),
    };
    CompiledSubcommands {
        children,
        declaration: Some(FacetDeclaration {
            id: "subcommands".to_owned(),
            kind: FacetKind::Collection,
            renderer: FacetRenderer::Collection,
            icon: ">".to_owned(),
            label: label.to_owned(),
            summary: summary.to_owned(),
            resource_kind: None,
            resolver: Some(FacetResolverDeclaration::Catalog {
                relation: "subcommands".to_owned(),
            }),
            view: facet.view.clone(),
        }),
    }
}
