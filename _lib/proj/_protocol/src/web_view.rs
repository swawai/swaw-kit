use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::{FacetRoute, ProtocolError, ProtocolResult, ResourceList};

pub const WEB_VIEW_SOURCE_SCHEMA: &str = "swawkit.view-source/web/v1";
pub const WEB_VIEW_BUNDLE_PROTOCOL: &str = "swawkit.view-bundle/web/v1";
pub const FACET_RESULT_RESOURCE: &str = "facet-result";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum WebColumnWidth {
    Normal,
    Wide,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(tag = "component", rename_all = "kebab-case", deny_unknown_fields)]
pub enum WebViewBody {
    ResourceList { source: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct WebColumnView {
    pub width: WebColumnWidth,
    pub body: WebViewBody,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct WebViewSource {
    pub schema: String,
    pub column: WebColumnView,
}

impl WebViewSource {
    pub fn resource_list(width: WebColumnWidth) -> Self {
        Self {
            schema: WEB_VIEW_SOURCE_SCHEMA.to_owned(),
            column: WebColumnView {
                width,
                body: WebViewBody::ResourceList {
                    source: FACET_RESULT_RESOURCE.to_owned(),
                },
            },
        }
    }

    pub fn validate(&self) -> ProtocolResult<()> {
        if self.schema != WEB_VIEW_SOURCE_SCHEMA {
            return Err(ProtocolError::new(format!(
                "Web View Source schema must be {WEB_VIEW_SOURCE_SCHEMA}"
            )));
        }
        match &self.column.body {
            WebViewBody::ResourceList { source } if source == FACET_RESULT_RESOURCE => Ok(()),
            WebViewBody::ResourceList { .. } => Err(ProtocolError::new(format!(
                "first-slice Resource List view source must be '{FACET_RESULT_RESOURCE}'"
            ))),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WebViewBundle {
    protocol: String,
    target: FacetRoute,
    view: WebColumnView,
    resources: BTreeMap<String, ResourceList>,
}

impl WebViewBundle {
    pub fn target(&self) -> &FacetRoute {
        &self.target
    }

    pub fn view(&self) -> &WebColumnView {
        &self.view
    }

    pub fn resources(&self) -> &BTreeMap<String, ResourceList> {
        &self.resources
    }

    pub fn validate(&self) -> ProtocolResult<()> {
        if self.protocol != WEB_VIEW_BUNDLE_PROTOCOL {
            return Err(ProtocolError::new(format!(
                "Web View Bundle protocol must be {WEB_VIEW_BUNDLE_PROTOCOL}"
            )));
        }
        self.target.validate()?;
        if self.resources.len() != 1 {
            return Err(ProtocolError::new(
                "first-slice Web View Bundle must contain one resolved resource",
            ));
        }
        let Some(resource) = self.resources.get(FACET_RESULT_RESOURCE) else {
            return Err(ProtocolError::new(
                "Web View Bundle is missing its Facet result",
            ));
        };
        resource.validate()?;
        if resource.source() != &self.target {
            return Err(ProtocolError::new(
                "Web View Bundle result does not belong to its target Facet",
            ));
        }
        match &self.view.body {
            WebViewBody::ResourceList { source } if source == FACET_RESULT_RESOURCE => Ok(()),
            WebViewBody::ResourceList { .. } => Err(ProtocolError::new(
                "Web View Bundle references an unavailable resource",
            )),
        }
    }
}

pub fn parse_web_view_source(bytes: &[u8]) -> ProtocolResult<WebViewSource> {
    let source: WebViewSource = serde_json::from_slice(bytes)
        .map_err(|error| ProtocolError::new(format!("invalid Web View Source JSON: {error}")))?;
    source.validate()?;
    Ok(source)
}

pub fn parse_web_view_bundle(bytes: &[u8]) -> ProtocolResult<WebViewBundle> {
    let bundle: WebViewBundle = serde_json::from_slice(bytes)
        .map_err(|error| ProtocolError::new(format!("invalid Web View Bundle JSON: {error}")))?;
    bundle.validate()?;
    Ok(bundle)
}

pub fn resolve_web_view(
    source: WebViewSource,
    target: FacetRoute,
    result: ResourceList,
) -> ProtocolResult<WebViewBundle> {
    source.validate()?;
    target.validate()?;
    result.validate()?;
    if result.source() != &target {
        return Err(ProtocolError::new(
            "cannot resolve a View with another Facet's Resource List",
        ));
    }
    let bundle = WebViewBundle {
        protocol: WEB_VIEW_BUNDLE_PROTOCOL.to_owned(),
        target,
        view: source.column,
        resources: BTreeMap::from([(FACET_RESULT_RESOURCE.to_owned(), result)]),
    };
    bundle.validate()?;
    Ok(bundle)
}

#[cfg(test)]
mod tests {
    use crate::{ResourceIdentity, ResourceListing, ResourceRoute};

    use super::*;

    fn source() -> WebViewSource {
        parse_web_view_source(
            br#"{
                "schema":"swawkit.view-source/web/v1",
                "column":{
                    "width":"wide",
                    "body":{"component":"resource-list","source":"facet-result"}
                }
            }"#,
        )
        .unwrap()
    }

    #[test]
    fn resolves_a_closed_bundle_from_one_facet_snapshot() {
        let target = FacetRoute::parse("$/system::dev/subcommands").unwrap();
        let list = ResourceList::new(
            target.clone(),
            vec![
                ResourceListing::new(
                    ResourceIdentity::static_resource(
                        ResourceRoute::parse("$/system::dev/subcommands::bun").unwrap(),
                    )
                    .unwrap(),
                    "bun",
                    ResourceRoute::parse("$/system::dev/subcommands::bun").unwrap(),
                    vec!["execute".to_owned()],
                    "Bun",
                    "JavaScript runtime",
                )
                .unwrap(),
            ],
        )
        .unwrap();
        let bundle = resolve_web_view(source(), target.clone(), list).unwrap();

        assert_eq!(bundle.target(), &target);
        assert_eq!(bundle.resources().len(), 1);
        assert_eq!(bundle.view().width, WebColumnWidth::Wide);
        let bytes = serde_json::to_vec(&bundle).unwrap();
        assert_eq!(parse_web_view_bundle(&bytes).unwrap(), bundle);
    }

    #[test]
    fn platform_default_is_the_normal_resource_list_view() {
        let source = WebViewSource::resource_list(WebColumnWidth::Normal);
        source.validate().unwrap();
        assert_eq!(source.column.width, WebColumnWidth::Normal);
        assert_eq!(
            source,
            parse_web_view_source(&serde_json::to_vec(&source).unwrap()).unwrap()
        );
    }

    #[test]
    fn another_facets_result_cannot_be_smuggled_into_the_bundle() {
        let target = FacetRoute::parse("$/system::dev/subcommands").unwrap();
        let foreign = ResourceList::new(
            FacetRoute::parse("$/system::context/contexts").unwrap(),
            Vec::new(),
        )
        .unwrap();
        assert!(resolve_web_view(source(), target, foreign).is_err());
    }

    #[test]
    fn rejects_raw_html_unknown_components_and_unresolved_aliases() {
        for invalid in [
            br#"{"schema":"swawkit.view-source/web/v1","column":{"width":"wide","body":{"component":"html","source":"<script>"}}}"#.as_slice(),
            br#"{"schema":"swawkit.view-source/web/v1","column":{"width":"wide","body":{"component":"resource-list","source":"remote"}}}"#.as_slice(),
            br#"{"schema":"swawkit.view-source/web/v1","column":{"width":"wide","body":{"component":"resource-list","source":"facet-result","style":"width:999px"}}}"#.as_slice(),
        ] {
            assert!(parse_web_view_source(invalid).is_err());
        }
    }
}
