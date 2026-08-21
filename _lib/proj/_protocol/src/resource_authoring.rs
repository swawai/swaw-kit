use serde::{Deserialize, Serialize};

use crate::{FacetRoute, ProtocolError, ProtocolResult, resource_route::is_windows_reserved_name};

pub const RESOURCE_SCHEMA: &str = "swawkit.resource/v1";
pub const RESOURCE_FACET_SCHEMA: &str = "swawkit.facet/v1";
pub const RESOURCE_KIND_SCHEMA: &str = "swawkit.resource-kind/v1";
pub const FACET_EXECUTION_SCHEMA: &str = "swawkit.facet-execution/v2";

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ResourceManifest {
    pub schema: String,
    pub kind: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ResourceFacetKind {
    Collection,
    Operation,
    Projection,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ResourceFacetManifest {
    pub schema: String,
    pub kind: ResourceFacetKind,
    #[serde(default)]
    pub presentation: Option<ResourceFacetPresentation>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ResourceFacetPresentation {
    pub icon: String,
    pub label: ResourceLocalizedText,
    pub summary: ResourceLocalizedText,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ResourceLocalizedText {
    #[serde(rename = "zh-CN")]
    pub zh_cn: String,
    pub en: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(untagged)]
pub enum ResourceKindManifest {
    Definition(ResourceKindDefinitionManifest),
    Reference(ResourceKindReferenceManifest),
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ResourceKindDefinitionManifest {
    pub schema: String,
    pub kind: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ResourceKindReferenceManifest {
    pub schema: String,
    #[serde(rename = "ref")]
    pub reference: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "kebab-case", deny_unknown_fields)]
pub enum FacetExecution {
    Core {
        handler: String,
    },
    Runtime {
        product: String,
    },
    Native,
    NativeDelegate {
        owner: String,
    },
    Invoke {
        target: String,
        #[serde(default)]
        arguments: Vec<FacetExecutionArgument>,
        #[serde(rename = "acceptsTail", default)]
        accepts_tail: bool,
        #[serde(default)]
        confirmation: Option<String>,
        #[serde(default)]
        returns: Option<String>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(untagged)]
pub enum FacetExecutionArgument {
    Literal(String),
    Binding(FacetExecutionArgumentBinding),
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct FacetExecutionArgumentBinding {
    pub bind: FacetExecutionBinding,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
pub enum FacetExecutionBinding {
    #[serde(rename = "resource.selector")]
    ResourceSelector,
    #[serde(rename = "resource.route")]
    ResourceRoute,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct FacetExecutionManifest {
    pub schema: String,
    pub implementation: FacetExecution,
}

pub fn parse_resource_manifest(bytes: &[u8]) -> ProtocolResult<ResourceManifest> {
    let manifest: ResourceManifest = parse(bytes, "Resource manifest")?;
    if manifest.schema != RESOURCE_SCHEMA {
        return Err(schema_error("Resource", &manifest.schema, RESOURCE_SCHEMA));
    }
    validate_kind(&manifest.kind)?;
    Ok(manifest)
}

pub fn parse_resource_facet_manifest(bytes: &[u8]) -> ProtocolResult<ResourceFacetManifest> {
    let manifest: ResourceFacetManifest = parse(bytes, "Resource Facet manifest")?;
    if manifest.schema != RESOURCE_FACET_SCHEMA {
        return Err(schema_error(
            "Resource Facet",
            &manifest.schema,
            RESOURCE_FACET_SCHEMA,
        ));
    }
    if let Some(presentation) = &manifest.presentation {
        validate_text(&presentation.icon, 8, "Facet icon")?;
        validate_localized(&presentation.label, 64, "Facet label")?;
        validate_localized(&presentation.summary, 200, "Facet summary")?;
    }
    Ok(manifest)
}

pub fn parse_resource_kind_manifest(bytes: &[u8]) -> ProtocolResult<ResourceKindManifest> {
    let manifest: ResourceKindManifest = parse(bytes, "Resource Kind manifest")?;
    let schema = match &manifest {
        ResourceKindManifest::Definition(definition) => &definition.schema,
        ResourceKindManifest::Reference(reference) => &reference.schema,
    };
    if schema != RESOURCE_KIND_SCHEMA {
        return Err(schema_error("Resource Kind", schema, RESOURCE_KIND_SCHEMA));
    }
    match &manifest {
        ResourceKindManifest::Definition(definition) => validate_kind(&definition.kind)?,
        ResourceKindManifest::Reference(reference) => {
            let route = FacetRoute::parse(&reference.reference)?;
            if route.to_string() != reference.reference {
                return Err(ProtocolError::new(
                    "Resource Kind ref must use canonical Facet Route syntax",
                ));
            }
        }
    }
    Ok(manifest)
}

pub fn parse_facet_execution_manifest(bytes: &[u8]) -> ProtocolResult<FacetExecutionManifest> {
    let manifest: FacetExecutionManifest = parse(bytes, "Facet Execution manifest")?;
    if manifest.schema != FACET_EXECUTION_SCHEMA {
        return Err(schema_error(
            "Facet Execution",
            &manifest.schema,
            FACET_EXECUTION_SCHEMA,
        ));
    }
    match &manifest.implementation {
        FacetExecution::Core { handler } => validate_handler(handler)?,
        FacetExecution::Runtime { product } => validate_kind(product)?,
        FacetExecution::Native => {}
        FacetExecution::NativeDelegate { owner } => {
            validate_execute_target(owner, "native delegate owner")?
        }
        FacetExecution::Invoke {
            target,
            arguments,
            accepts_tail,
            confirmation,
            returns,
        } => {
            validate_execute_target(target, "invoke target")?;
            if arguments.len() > 32 {
                return Err(ProtocolError::new(
                    "Facet invoke execution cannot declare more than 32 arguments",
                ));
            }
            for argument in arguments {
                if let FacetExecutionArgument::Literal(value) = argument {
                    validate_bounded_value(value, 4096, "Facet invoke argument")?;
                }
            }
            if *accepts_tail && confirmation.is_some() {
                return Err(ProtocolError::new(
                    "Facet invoke execution cannot combine tail arguments with confirmation",
                ));
            }
            if let Some(value) = confirmation {
                validate_text(value, 500, "Facet confirmation")?;
            }
            if let Some(value) = returns {
                validate_text(value, 128, "Facet returned protocol")?;
            }
        }
    }
    Ok(manifest)
}

fn parse<T>(bytes: &[u8], name: &str) -> ProtocolResult<T>
where
    T: for<'de> Deserialize<'de>,
{
    serde_json::from_slice(bytes)
        .map_err(|error| ProtocolError::new(format!("invalid {name} JSON: {error}")))
}

fn validate_kind(value: &str) -> ProtocolResult<()> {
    let valid = !value.is_empty()
        && value.len() <= 32
        && !is_windows_reserved_name(value)
        && value.bytes().enumerate().all(|(index, byte)| {
            byte.is_ascii_lowercase() || (index > 0 && (byte.is_ascii_digit() || byte == b'-'))
        });
    if valid {
        Ok(())
    } else {
        Err(ProtocolError::new(
            "Resource kind must match [a-z][a-z0-9-]{0,31}",
        ))
    }
}

fn validate_handler(value: &str) -> ProtocolResult<()> {
    let valid = !value.is_empty()
        && value.len() <= 128
        && value.split('.').all(|segment| {
            !segment.is_empty()
                && segment.bytes().enumerate().all(|(index, byte)| {
                    byte.is_ascii_lowercase()
                        || (index > 0 && (byte.is_ascii_digit() || byte == b'-'))
                })
        });
    if valid {
        Ok(())
    } else {
        Err(ProtocolError::new(
            "Core Facet handler must be a bounded dot-separated lower-kebab name",
        ))
    }
}

fn validate_execute_target(value: &str, field: &str) -> ProtocolResult<()> {
    let route = FacetRoute::parse(value)?;
    if route.facet() != "execute" {
        return Err(ProtocolError::new(format!(
            "Facet {field} must name an execute Facet"
        )));
    }
    Ok(())
}

fn validate_localized(
    value: &ResourceLocalizedText,
    maximum: usize,
    field: &str,
) -> ProtocolResult<()> {
    validate_text(&value.zh_cn, maximum, field)?;
    validate_text(&value.en, maximum, field)
}

fn validate_text(value: &str, maximum: usize, field: &str) -> ProtocolResult<()> {
    validate_bounded_value(value, maximum, field)?;
    if value.trim() != value {
        return Err(ProtocolError::new(format!(
            "{field} must not contain leading or trailing whitespace"
        )));
    }
    Ok(())
}

fn validate_bounded_value(value: &str, maximum: usize, field: &str) -> ProtocolResult<()> {
    if value.is_empty() || value.contains('\0') || value.chars().count() > maximum {
        Err(ProtocolError::new(format!(
            "{field} must contain 1 to {maximum} characters"
        )))
    } else {
        Ok(())
    }
}

fn schema_error(name: &str, actual: &str, expected: &str) -> ProtocolError {
    ProtocolError::new(format!(
        "unsupported {name} schema '{actual}'; expected '{expected}'"
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn authoring_protocols_are_narrow_and_independently_versioned() {
        parse_resource_manifest(br#"{"schema":"swawkit.resource/v1","kind":"command"}"#).unwrap();
        parse_resource_facet_manifest(br#"{"schema":"swawkit.facet/v1","kind":"collection"}"#)
            .unwrap();
        parse_resource_kind_manifest(br#"{"schema":"swawkit.resource-kind/v1","kind":"context"}"#)
            .unwrap();
        parse_resource_kind_manifest(
            br#"{"schema":"swawkit.resource-kind/v1","ref":"$/system::runs/all"}"#,
        )
        .unwrap();
        parse_facet_execution_manifest(
            br#"{"schema":"swawkit.facet-execution/v2","implementation":{"type":"runtime","product":"dev"}}"#,
        )
        .unwrap();
        parse_facet_execution_manifest(
            br#"{"schema":"swawkit.facet-execution/v2","implementation":{"type":"invoke","target":"$/system::context/subcommands::show/execute","arguments":[{"bind":"resource.selector"}],"returns":"swawkit.context/v2"}}"#,
        )
        .unwrap();
        parse_facet_execution_manifest(
            br#"{"schema":"swawkit.facet-execution/v2","implementation":{"type":"invoke","target":"$/system::runs/execute","arguments":["--json",{"bind":"resource.route"}],"returns":"swawkit.resource-list/v2"}}"#,
        )
        .unwrap();
    }

    #[test]
    fn listed_and_class_are_not_parallel_authoring_modes() {
        for invalid_resource in [
            br#"{"schema":"swawkit.listed/v1","kind":"command"}"#.as_slice(),
            br#"{"schema":"swawkit.resource/v1","class":"command"}"#.as_slice(),
        ] {
            assert!(parse_resource_manifest(invalid_resource).is_err());
        }
        let retired_store = br#"{"schema":"swawkit.resource-kind/v1","kind":"context","store":{"type":"facet-data"}}"#;
        assert!(parse_resource_kind_manifest(retired_store).is_err());
        let mixed_definition_and_reference =
            br#"{"schema":"swawkit.resource-kind/v1","kind":"run","ref":"$/system::runs/all"}"#;
        assert!(parse_resource_kind_manifest(mixed_definition_and_reference).is_err());
    }

    #[test]
    fn execution_is_owned_by_the_facet_protocol() {
        let legacy = br#"{"schema":"swawkit.command-module/v12","execution":{"type":"runtime","product":"dev"}}"#;
        assert!(parse_facet_execution_manifest(legacy).is_err());

        let retired_v1 = br#"{"schema":"swawkit.facet-execution/v1","implementation":{"type":"runtime","product":"dev"}}"#;
        assert!(parse_facet_execution_manifest(retired_v1).is_err());

        let extended = br#"{"schema":"swawkit.facet-execution/v2","implementation":{"type":"runtime","product":"dev"},"mode":"legacy"}"#;
        assert!(parse_facet_execution_manifest(extended).is_err());

        for retired_type in ["command", "delegate"] {
            let retired = format!(
                r#"{{"schema":"swawkit.facet-execution/v2","implementation":{{"type":"{retired_type}","target":"$/system::runs/execute"}}}}"#
            );
            assert!(parse_facet_execution_manifest(retired.as_bytes()).is_err());
        }
    }

    #[test]
    fn filesystem_backed_kinds_reject_reserved_directory_names() {
        assert!(
            parse_resource_manifest(br#"{"schema":"swawkit.resource/v1","kind":"con"}"#).is_err()
        );
        assert!(
            parse_resource_kind_manifest(
                br#"{"schema":"swawkit.resource-kind/v1","kind":"com1"}"#,
            )
            .is_err()
        );
    }
}
