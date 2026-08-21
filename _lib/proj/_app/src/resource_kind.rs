use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};
use swawkit_proj_protocol::{FacetRoute, WebViewSource};

use crate::facet::{Facet, FacetKind, FacetRenderer, FacetResolver};

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ResourceKindRef {
    pub source: FacetRoute,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ResourceKind {
    pub kind: String,
    pub source: FacetRoute,
    pub facets: Vec<ResourceFacetTemplate>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ResourceFacetTemplate {
    pub id: String,
    pub kind: FacetKind,
    pub renderer: FacetRenderer,
    pub icon: String,
    pub label: String,
    pub summary: String,
    pub resolver: ResourceFacetResolver,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub view: Option<WebViewSource>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "lowercase", deny_unknown_fields)]
pub enum ResourceFacetResolver {
    Command {
        address: String,
        arguments: Vec<ResourceFacetArgument>,
        #[serde(rename = "acceptsTail", default, skip_serializing_if = "is_false")]
        accepts_tail: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        confirmation: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        returns: Option<String>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(untagged)]
pub enum ResourceFacetArgument {
    Literal(String),
    Binding(ResourceFacetArgumentBinding),
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ResourceFacetArgumentBinding {
    pub bind: ResourceFacetBinding,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
pub enum ResourceFacetBinding {
    #[serde(rename = "resource.selector")]
    ResourceSelector,
}

impl ResourceKind {
    pub fn validate(&self) -> Result<(), String> {
        if !valid_token(&self.kind) {
            return Err("Resource kind must match [a-z][a-z0-9-]{0,31}".to_owned());
        }
        self.source.validate().map_err(|error| error.to_string())?;
        if self.facets.is_empty() || self.facets.len() > 32 {
            return Err("Resource kind must declare 1 to 32 Facet templates".to_owned());
        }
        let mut identifiers = BTreeSet::new();
        for facet in &self.facets {
            if !identifiers.insert(facet.id.as_str()) {
                return Err("Resource kind contains a duplicate Facet id".to_owned());
            }
            facet.validate()?;
        }
        Ok(())
    }

    pub fn instantiate(&self, facet_id: &str, selector: &str) -> Result<Option<Facet>, String> {
        if !valid_resource_selector(selector) {
            return Err("Resource selector is invalid".to_owned());
        }
        self.facets
            .iter()
            .find(|facet| facet.id == facet_id)
            .map(|facet| facet.instantiate(selector))
            .transpose()
    }
}

impl ResourceKindRef {
    pub fn validate(&self) -> Result<(), String> {
        self.source.validate().map_err(|error| error.to_string())
    }
}

impl ResourceFacetTemplate {
    fn validate(&self) -> Result<(), String> {
        let facet = self.instantiate("resource")?;
        facet.validate()?;
        if facet.kind == FacetKind::Collection {
            return Err("Resource Facet templates cannot expose nested collections".to_owned());
        }
        if facet.kind == FacetKind::Operation && facet.renderer != FacetRenderer::Run {
            return Err("Resource operation templates must use the run renderer".to_owned());
        }
        Ok(())
    }

    fn instantiate(&self, selector: &str) -> Result<Facet, String> {
        let resolver = match &self.resolver {
            ResourceFacetResolver::Command {
                address,
                arguments,
                accepts_tail,
                confirmation,
                returns,
            } => FacetResolver::Command {
                address: address.clone(),
                arguments: arguments
                    .iter()
                    .map(|argument| match argument {
                        ResourceFacetArgument::Literal(value) => value.clone(),
                        ResourceFacetArgument::Binding(binding) => match binding.bind {
                            ResourceFacetBinding::ResourceSelector => selector.to_owned(),
                        },
                    })
                    .collect(),
                accepts_tail: *accepts_tail,
                confirmation: confirmation.clone(),
                returns: returns.clone(),
            },
        };
        Ok(Facet {
            id: self.id.clone(),
            kind: self.kind,
            renderer: self.renderer,
            icon: self.icon.clone(),
            label: self.label.clone(),
            summary: self.summary.clone(),
            resource_kind: None,
            resolver: Some(resolver),
            view: self.view.clone(),
        })
    }
}

fn is_false(value: &bool) -> bool {
    !value
}

fn valid_token(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 32
        && value.bytes().enumerate().all(|(index, byte)| {
            byte.is_ascii_lowercase() || (index > 0 && (byte.is_ascii_digit() || byte == b'-'))
        })
}

fn valid_resource_selector(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value.bytes().enumerate().all(|(index, byte)| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || (index > 0 && byte == b'-')
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn typed_resource_selector_binding_materializes_one_concrete_facet() {
        let kind = ResourceKind {
            kind: "context".to_owned(),
            source: FacetRoute::parse("$/system::context/contexts").unwrap(),
            facets: vec![ResourceFacetTemplate {
                id: "show".to_owned(),
                kind: FacetKind::Projection,
                renderer: FacetRenderer::Overview,
                icon: "i".to_owned(),
                label: "Overview".to_owned(),
                summary: "Inspect this Context".to_owned(),
                resolver: ResourceFacetResolver::Command {
                    address: ".context/show".to_owned(),
                    arguments: vec![ResourceFacetArgument::Binding(
                        ResourceFacetArgumentBinding {
                            bind: ResourceFacetBinding::ResourceSelector,
                        },
                    )],
                    accepts_tail: false,
                    confirmation: None,
                    returns: Some("swawkit.context/v2".to_owned()),
                },
                view: None,
            }],
        };

        kind.validate().expect("valid Resource kind");
        let facet = kind
            .instantiate("show", "release-check")
            .expect("materialize Facet")
            .expect("known Facet");
        let FacetResolver::Command { arguments, .. } = facet.resolver.expect("resolver") else {
            panic!("expected command resolver");
        };
        assert_eq!(arguments, ["release-check"]);
    }

    #[test]
    fn resource_kind_refs_name_one_exact_definition_source() {
        ResourceKindRef {
            source: FacetRoute::parse("$/system::runs/all").unwrap(),
        }
        .validate()
        .expect("definition source");
    }
}
