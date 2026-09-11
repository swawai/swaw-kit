use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use crate::{ProtocolError, ProtocolResult, ResourceRoute};

pub const FACET_REQUIREMENTS_SCHEMA: &str = "swawkit.facet-requirements/v1";
pub const RESOURCE_EXPORTS_SCHEMA: &str = "swawkit.resource-exports/v1";
pub const MAX_FACET_REQUIREMENTS: usize = 64;
pub const MAX_RESOURCE_EXPORTS: usize = 64;

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FacetRequirement {
    pub provider: String,
    pub export: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FacetRequirementsManifest {
    pub schema: String,
    pub requirements: Vec<FacetRequirement>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ResourceExport {
    pub id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ResourceExportsManifest {
    pub schema: String,
    pub exports: Vec<ResourceExport>,
}

pub fn parse_facet_requirements_manifest(
    bytes: &[u8],
) -> ProtocolResult<FacetRequirementsManifest> {
    let manifest: FacetRequirementsManifest = parse(bytes, "Facet Requirements")?;
    if manifest.schema != FACET_REQUIREMENTS_SCHEMA {
        return Err(schema_error(
            "Facet Requirements",
            &manifest.schema,
            FACET_REQUIREMENTS_SCHEMA,
        ));
    }
    if manifest.requirements.len() > MAX_FACET_REQUIREMENTS {
        return Err(ProtocolError::new(format!(
            "Facet Requirements cannot contain more than {MAX_FACET_REQUIREMENTS} items"
        )));
    }
    let mut seen = BTreeSet::new();
    for requirement in &manifest.requirements {
        let provider = ResourceRoute::parse(&requirement.provider)?;
        if provider == ResourceRoute::root()
            || provider.canonical_route() != requirement.provider
            || !valid_token(&requirement.export)
            || !seen.insert((&requirement.provider, &requirement.export))
        {
            return Err(ProtocolError::new(
                "invalid or duplicate Facet requirement provider/export",
            ));
        }
    }
    Ok(manifest)
}

pub fn parse_resource_exports_manifest(bytes: &[u8]) -> ProtocolResult<ResourceExportsManifest> {
    let manifest: ResourceExportsManifest = parse(bytes, "Resource Exports")?;
    if manifest.schema != RESOURCE_EXPORTS_SCHEMA {
        return Err(schema_error(
            "Resource Exports",
            &manifest.schema,
            RESOURCE_EXPORTS_SCHEMA,
        ));
    }
    if manifest.exports.len() > MAX_RESOURCE_EXPORTS {
        return Err(ProtocolError::new(format!(
            "Resource Exports cannot contain more than {MAX_RESOURCE_EXPORTS} items"
        )));
    }
    let mut seen = BTreeSet::new();
    if manifest
        .exports
        .iter()
        .any(|export| !valid_token(&export.id) || !seen.insert(&export.id))
    {
        return Err(ProtocolError::new(
            "invalid or duplicate Resource export id",
        ));
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

fn valid_token(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 32
        && value.bytes().enumerate().all(|(index, byte)| {
            byte.is_ascii_lowercase() || (index > 0 && (byte.is_ascii_digit() || byte == b'-'))
        })
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
    fn requirements_name_resource_providers_instead_of_legacy_command_addresses() {
        let manifest = parse_facet_requirements_manifest(
            br#"{"schema":"swawkit.facet-requirements/v1","requirements":[{"provider":"$/system::dev/subcommands::setup","export":"environment"}]}"#,
        )
        .unwrap();
        assert_eq!(
            manifest.requirements[0].provider,
            "$/system::dev/subcommands::setup"
        );

        assert!(
            parse_facet_requirements_manifest(
                br#"{"schema":"swawkit.facet-requirements/v1","requirements":[{"provider":".dev/setup","export":"environment"}]}"#,
            )
            .is_err()
        );
    }

    #[test]
    fn capability_documents_are_strict_bounded_and_unique() {
        parse_resource_exports_manifest(
            br#"{"schema":"swawkit.resource-exports/v1","exports":[{"id":"environment"}]}"#,
        )
        .unwrap();
        assert!(
            parse_resource_exports_manifest(
                br#"{"schema":"swawkit.resource-exports/v1","exports":[{"id":"environment"},{"id":"environment"}]}"#,
            )
            .is_err()
        );
        assert!(
            parse_facet_requirements_manifest(
                br#"{"schema":"swawkit.facet-requirements/v1","requirements":[],"legacy":true}"#,
            )
            .is_err()
        );
    }
}
