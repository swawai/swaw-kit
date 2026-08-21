use serde::{Deserialize, Serialize};
use swawkit_proj_protocol::{RESOURCE_LIST_PROTOCOL, WebViewSource};

use crate::resource_kind::ResourceKindRef;

const MAX_ARGUMENTS: usize = 32;
const MAX_ARGUMENT_LENGTH: usize = 4096;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Facet {
    pub id: String,
    pub kind: FacetKind,
    pub renderer: FacetRenderer,
    pub icon: String,
    pub label: String,
    pub summary: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resource_kind: Option<ResourceKindRef>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resolver: Option<FacetResolver>,
    #[serde(skip_serializing)]
    pub view: Option<WebViewSource>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum FacetKind {
    Collection,
    Operation,
    Projection,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum FacetRenderer {
    Collection,
    Edit,
    Help,
    Overview,
    Run,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "lowercase", deny_unknown_fields)]
pub enum FacetResolver {
    Catalog {
        relation: String,
    },
    Command {
        address: String,
        arguments: Vec<String>,
        #[serde(rename = "acceptsTail", default, skip_serializing_if = "is_false")]
        accepts_tail: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        confirmation: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        returns: Option<String>,
    },
}

impl Facet {
    pub fn validate(&self) -> Result<(), String> {
        if !valid_facet_id(&self.id) {
            return Err("facet id must match [a-z][a-z0-9-]{0,31}".to_owned());
        }
        validate_text(&self.icon, 8, "facet icon")?;
        validate_text(&self.label, 64, "facet label")?;
        validate_text(&self.summary, 200, "facet summary")?;

        let renderer_matches = match self.kind {
            FacetKind::Collection => self.renderer == FacetRenderer::Collection,
            FacetKind::Projection => self.renderer == FacetRenderer::Overview,
            FacetKind::Operation => !matches!(
                self.renderer,
                FacetRenderer::Collection | FacetRenderer::Overview
            ),
        };
        if !renderer_matches {
            return Err("facet kind and renderer are incompatible".to_owned());
        }
        if let Some(view) = &self.view {
            view.validate().map_err(|error| error.to_string())?;
            if self.kind != FacetKind::Collection {
                return Err("first-slice Web View is only valid for a collection Facet".to_owned());
            }
        }

        match (&self.kind, &self.resolver, &self.resource_kind) {
            (FacetKind::Collection, Some(FacetResolver::Command { .. }), Some(resource_kind))
                if resource_kind.validate().is_ok() => {}
            (FacetKind::Collection, Some(FacetResolver::Catalog { .. }), None) => {}
            (FacetKind::Collection, _, _) => {
                return Err(
                    "a command-resolved collection must declare one valid resourceKind".to_owned(),
                );
            }
            (_, _, None) => {}
            _ => return Err("only a collection Facet may declare resourceKind".to_owned()),
        }

        match &self.resolver {
            None => return Err("facet must declare a resolver".to_owned()),
            Some(FacetResolver::Catalog { relation }) => {
                if self.kind != FacetKind::Collection || relation != "subcommands" {
                    return Err(
                        "a catalog resolver is only valid for the subcommands Collection"
                            .to_owned(),
                    );
                }
            }
            Some(FacetResolver::Command {
                address,
                arguments,
                accepts_tail,
                confirmation,
                returns,
            }) => {
                validate_command_resolver(
                    self,
                    address,
                    arguments,
                    *accepts_tail,
                    confirmation.as_deref(),
                    returns.as_deref(),
                )?;
            }
        }

        let required_target = (self.renderer == FacetRenderer::Help).then_some(".help");
        if let Some(required_target) = required_target {
            let target = match &self.resolver {
                Some(FacetResolver::Command { address, .. }) => address.as_str(),
                _ => "",
            };
            if target != required_target {
                return Err(format!(
                    "the {:?} renderer requires the {required_target} command resolver",
                    self.renderer
                ));
            }
        }
        Ok(())
    }
}

fn validate_command_resolver(
    facet: &Facet,
    address: &str,
    arguments: &[String],
    accepts_tail: bool,
    confirmation: Option<&str>,
    returns: Option<&str>,
) -> Result<(), String> {
    if address.is_empty() || address.len() > 256 || address.contains('\0') {
        return Err("facet command resolver address is invalid".to_owned());
    }
    if arguments.len() > MAX_ARGUMENTS
        || arguments
            .iter()
            .any(|value| value.len() > MAX_ARGUMENT_LENGTH || value.contains('\0'))
    {
        return Err("facet command resolver arguments exceed their limits".to_owned());
    }
    if let Some(value) = confirmation {
        validate_text(value, 500, "facet confirmation")?;
    }
    if let Some(value) = returns {
        validate_text(value, 128, "facet returned protocol")?;
    }
    if accepts_tail && confirmation.is_some() {
        return Err("facet resolver cannot combine tail arguments with confirmation".to_owned());
    }
    match facet.kind {
        FacetKind::Collection => {
            if returns != Some(RESOURCE_LIST_PROTOCOL) || accepts_tail || confirmation.is_some() {
                return Err(format!(
                    "collection facet resolver must return {RESOURCE_LIST_PROTOCOL} without interactive input"
                ));
            }
        }
        FacetKind::Projection => {
            if returns.is_none()
                || returns == Some(RESOURCE_LIST_PROTOCOL)
                || accepts_tail
                || confirmation.is_some()
            {
                return Err(
                    "projection facet resolver must declare non-collection returns without interactive input"
                        .to_owned(),
                );
            }
        }
        FacetKind::Operation => {
            if returns.is_some() {
                return Err("operation facet resolver cannot return a document".to_owned());
            }
        }
    }
    Ok(())
}

pub(crate) fn valid_facet_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 32
        && value.bytes().enumerate().all(|(index, byte)| {
            byte.is_ascii_lowercase() || (index > 0 && (byte.is_ascii_digit() || byte == b'-'))
        })
}

fn validate_text(value: &str, maximum: usize, field: &str) -> Result<(), String> {
    if value.is_empty() || value.trim() != value || value.chars().count() > maximum {
        Err(format!(
            "{field} must contain 1 to {maximum} trimmed characters"
        ))
    } else {
        Ok(())
    }
}

fn is_false(value: &bool) -> bool {
    !value
}
