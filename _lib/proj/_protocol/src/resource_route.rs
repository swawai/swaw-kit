use std::fmt;

use serde::{Deserialize, Serialize};

use crate::{CommandIdentity, CommandSpace, ProtocolError, ProtocolResult};

pub const MAX_RESOURCE_ROUTE_BYTES: usize = 1024;
pub const MAX_RESOURCE_ROUTE_HOPS: usize = 32;

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// One Collection Facet selection made while traversing a logical Resource graph.
pub struct ResourceHop {
    facet: String,
    selector: String,
}

impl ResourceHop {
    pub fn new(facet: impl Into<String>, selector: impl Into<String>) -> ProtocolResult<Self> {
        let hop = Self {
            facet: facet.into(),
            selector: selector.into(),
        };
        hop.validate()?;
        Ok(hop)
    }

    pub fn facet(&self) -> &str {
        &self.facet
    }

    pub fn selector(&self) -> &str {
        &self.selector
    }

    fn validate(&self) -> ProtocolResult<()> {
        validate_facet_id(&self.facet)?;
        validate_resource_selector(&self.selector)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// A logical access route whose terminal value is a Resource.
///
/// This is not the backing command execution, DataRoot, Release, or Journal identity.
pub struct ResourceRoute {
    hops: Vec<ResourceHop>,
}

impl ResourceRoute {
    pub fn root() -> Self {
        Self { hops: Vec::new() }
    }

    pub fn new(hops: Vec<ResourceHop>) -> ProtocolResult<Self> {
        let reference = Self { hops };
        reference.validate()?;
        Ok(reference)
    }

    pub fn parse(route: &str) -> ProtocolResult<Self> {
        match parse_route(route)? {
            RouteTarget::Resource(route) => Ok(route),
            RouteTarget::Facet(_) => Err(ProtocolError::new(format!(
                "resource route '{route}' ends at a Facet"
            ))),
        }
    }

    pub fn child(&self, facet: &str, selector: &str) -> ProtocolResult<Self> {
        let mut hops = self.hops.clone();
        hops.push(ResourceHop::new(facet, selector)?);
        Self::new(hops)
    }

    pub fn hops(&self) -> &[ResourceHop] {
        &self.hops
    }

    pub fn canonical_route(&self) -> String {
        let mut route = String::from("$");
        for hop in &self.hops {
            route.push('/');
            route.push_str(hop.facet());
            route.push_str("::");
            route.push_str(hop.selector());
        }
        route
    }

    pub fn validate(&self) -> ProtocolResult<()> {
        if self.hops.len() > MAX_RESOURCE_ROUTE_HOPS {
            return Err(ProtocolError::new(format!(
                "resource route cannot contain more than {MAX_RESOURCE_ROUTE_HOPS} hops"
            )));
        }
        for hop in &self.hops {
            hop.validate()?;
        }
        if self.canonical_route().len() > MAX_RESOURCE_ROUTE_BYTES {
            return Err(ProtocolError::new(format!(
                "resource route cannot exceed {MAX_RESOURCE_ROUTE_BYTES} bytes"
            )));
        }
        Ok(())
    }
}

impl fmt::Display for ResourceRoute {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.canonical_route())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// A logical method address: one Resource route plus its terminal Facet.
pub struct FacetRoute {
    resource: ResourceRoute,
    facet: String,
}

impl FacetRoute {
    pub fn new(resource: ResourceRoute, facet: impl Into<String>) -> ProtocolResult<Self> {
        let reference = Self {
            resource,
            facet: facet.into(),
        };
        reference.validate()?;
        Ok(reference)
    }

    pub fn parse(route: &str) -> ProtocolResult<Self> {
        match parse_route(route)? {
            RouteTarget::Facet(route) => Ok(route),
            RouteTarget::Resource(_) => Err(ProtocolError::new(format!(
                "Facet route '{route}' ends at a Resource"
            ))),
        }
    }

    pub fn resource(&self) -> &ResourceRoute {
        &self.resource
    }

    pub fn facet(&self) -> &str {
        &self.facet
    }

    pub fn canonical_route(&self) -> String {
        format!("{}/{}", self.resource.canonical_route(), self.facet)
    }

    pub fn validate(&self) -> ProtocolResult<()> {
        self.resource.validate()?;
        validate_facet_id(&self.facet)?;
        if self.canonical_route().len() > MAX_RESOURCE_ROUTE_BYTES {
            return Err(ProtocolError::new(format!(
                "Facet route cannot exceed {MAX_RESOURCE_ROUTE_BYTES} bytes"
            )));
        }
        Ok(())
    }
}

impl fmt::Display for FacetRoute {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.canonical_route())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
/// The explicit terminal kind returned when parsing canonical Route syntax.
pub enum RouteTarget {
    Resource(ResourceRoute),
    Facet(FacetRoute),
}

impl RouteTarget {
    pub fn canonical_route(&self) -> String {
        match self {
            Self::Resource(reference) => reference.canonical_route(),
            Self::Facet(reference) => reference.canonical_route(),
        }
    }
}

pub fn parse_route(route: &str) -> ProtocolResult<RouteTarget> {
    if route.len() > MAX_RESOURCE_ROUTE_BYTES {
        return Err(invalid_route(route, "route is too long"));
    }
    if route == "$" {
        return Ok(RouteTarget::Resource(ResourceRoute::root()));
    }
    let Some(suffix) = route.strip_prefix("$/") else {
        return Err(invalid_route(route, "route must begin with '$/'"));
    };
    if suffix.is_empty() {
        return Err(invalid_route(route, "route contains an empty Facet"));
    }

    let segments = suffix.split('/').collect::<Vec<_>>();
    if segments.len() > MAX_RESOURCE_ROUTE_HOPS + 1 {
        return Err(invalid_route(route, "route contains too many hops"));
    }

    let mut resource = ResourceRoute::root();
    for (index, segment) in segments.iter().enumerate() {
        let last = index + 1 == segments.len();
        let mut parts = segment.split("::");
        let facet = parts.next().unwrap_or_default();
        let selector = parts.next();
        if parts.next().is_some() {
            return Err(invalid_route(
                route,
                "route segment contains more than one selector",
            ));
        }
        validate_facet_id(facet).map_err(|_| invalid_route(route, "invalid Facet id"))?;
        match selector {
            Some(selector) => {
                validate_resource_selector(selector)
                    .map_err(|_| invalid_route(route, "invalid Resource selector"))?;
                resource = resource.child(facet, selector)?;
            }
            None if last => {
                return Ok(RouteTarget::Facet(FacetRoute::new(resource, facet)?));
            }
            None => {
                return Err(invalid_route(
                    route,
                    "an intermediate Facet must select one Resource",
                ));
            }
        }
    }
    Ok(RouteTarget::Resource(resource))
}

pub fn command_resource_route(command: &CommandIdentity) -> ProtocolResult<ResourceRoute> {
    let mut segments = command.path().iter();
    let mut reference = match command.space() {
        CommandSpace::System => ResourceRoute::root().child(
            "system",
            segments
                .next()
                .expect("Command identity always contains one path segment"),
        )?,
        CommandSpace::Module => ResourceRoute::root().child(
            "modules",
            command
                .namespace()
                .expect("Module command identity always has a namespace"),
        )?,
    };
    for segment in segments {
        reference = reference.child("subcommands", segment)?;
    }
    Ok(reference)
}

pub(crate) fn validate_facet_id(value: &str) -> ProtocolResult<()> {
    if valid_lower_kebab(value, 32, true) && !is_windows_reserved_name(value) {
        Ok(())
    } else {
        Err(ProtocolError::new(
            "Facet id must be a portable [a-z][a-z0-9-]{0,31} name",
        ))
    }
}

pub(crate) fn validate_resource_selector(value: &str) -> ProtocolResult<()> {
    if valid_lower_kebab(value, 128, false) && !is_windows_reserved_name(value) {
        Ok(())
    } else {
        Err(ProtocolError::new(
            "Resource selector must be a portable [a-z0-9][a-z0-9-]{0,127} name",
        ))
    }
}

pub(crate) fn is_windows_reserved_name(value: &str) -> bool {
    matches!(
        value,
        "con"
            | "prn"
            | "aux"
            | "nul"
            | "com1"
            | "com2"
            | "com3"
            | "com4"
            | "com5"
            | "com6"
            | "com7"
            | "com8"
            | "com9"
            | "lpt1"
            | "lpt2"
            | "lpt3"
            | "lpt4"
            | "lpt5"
            | "lpt6"
            | "lpt7"
            | "lpt8"
            | "lpt9"
    )
}

fn valid_lower_kebab(value: &str, maximum: usize, first_must_be_letter: bool) -> bool {
    !value.is_empty()
        && value.len() <= maximum
        && value.bytes().enumerate().all(|(index, byte)| {
            byte.is_ascii_lowercase()
                || (!first_must_be_letter && byte.is_ascii_digit())
                || (index > 0 && (byte.is_ascii_digit() || byte == b'-'))
        })
}

fn invalid_route(route: &str, reason: &str) -> ProtocolError {
    ProtocolError::new(format!("invalid Resource Route '{route}': {reason}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonical_route_alternates_facets_and_selected_resources() {
        let route = "$/system::dev/subcommands::bun/subcommands::mode/execute";
        let facet = FacetRoute::parse(route).expect("valid static Facet route");
        assert_eq!(facet.facet(), "execute");
        assert_eq!(facet.resource().hops().len(), 3);
        assert_eq!(facet.canonical_route(), route);

        let dynamic = ResourceRoute::parse("$/system::context/contexts::release-check")
            .expect("valid dynamic Resource route");
        assert_eq!(dynamic.hops()[1].facet(), "contexts");
        assert_eq!(dynamic.hops()[1].selector(), "release-check");
    }

    #[test]
    fn route_kind_is_explicit_at_the_terminal_segment() {
        assert!(ResourceRoute::parse("$/system::dev").is_ok());
        assert!(ResourceRoute::parse("$/system::dev/execute").is_err());
        assert!(FacetRoute::parse("$/system::dev/execute").is_ok());
        assert!(FacetRoute::parse("$/system::dev").is_err());
    }

    #[test]
    fn rejects_implicit_or_type_directed_route_grammar() {
        for invalid in [
            ".dev/bun",
            "$/system/dev",
            "$/system::dev/bun/execute",
            "$/system::dev/subcommands::bun::mode",
            "$/System::dev",
            "$/system::Dev",
            "$/system::dev/",
            "$/system::dev//execute",
        ] {
            assert!(parse_route(invalid).is_err(), "{invalid}");
        }
    }

    #[test]
    fn structured_routes_reject_unvalidated_wire_values() {
        let invalid: ResourceRoute =
            serde_json::from_str(r#"{"hops":[{"facet":"System","selector":"dev"}]}"#)
                .expect("shape is valid JSON");
        assert!(invalid.validate().is_err());
    }

    #[test]
    fn resource_selectors_are_portable_directory_names() {
        assert!(ResourceRoute::root().child("items", "42").is_ok());
        for reserved in ["con", "nul", "com1", "lpt9"] {
            assert!(ResourceRoute::root().child("items", reserved).is_err());
        }
    }

    #[test]
    fn command_identity_projects_to_one_canonical_resource_route() {
        assert_eq!(
            command_resource_route(&CommandIdentity::parse(".dev/bun/mode").unwrap())
                .unwrap()
                .canonical_route(),
            "$/system::dev/subcommands::bun/subcommands::mode"
        );
        assert_eq!(
            command_resource_route(&CommandIdentity::parse("swaw/context/show").unwrap())
                .unwrap()
                .canonical_route(),
            "$/modules::swaw/subcommands::context/subcommands::show"
        );
    }
}
