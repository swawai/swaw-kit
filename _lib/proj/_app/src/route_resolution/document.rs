use crate::{
    catalog::CommandNode,
    command_check::COMMAND_CHECK_PROTOCOL,
    facet::{Facet, FacetKind, FacetResolver},
};
use swawkit_proj_protocol::{RESOURCE_LIST_PROTOCOL, ResourceList};

use super::{ResolvedFacetDocument, RouteResolutionError, RouteResolver};

impl RouteResolver<'_> {
    pub(super) fn resolve_declared_facet(
        &self,
        facet: &Facet,
    ) -> Result<ResolvedFacetDocument, RouteResolutionError> {
        if facet.kind == FacetKind::Operation {
            return Err(RouteResolutionError::invalid(
                "operation facets must run through the command execution boundary",
            ));
        }
        let Some(FacetResolver::Command {
            address,
            arguments,
            accepts_tail,
            confirmation,
            returns,
        }) = &facet.resolver
        else {
            return Err(RouteResolutionError::invalid(
                "the requested facet has no document resolver",
            ));
        };
        if *accepts_tail || confirmation.is_some() {
            return Err(RouteResolutionError::invalid(
                "document resolvers must use exact arguments without confirmation",
            ));
        }
        let returns = returns.as_deref().ok_or_else(|| {
            RouteResolutionError::invalid("document resolvers must declare their return protocol")
        })?;
        if (facet.kind == FacetKind::Collection) != (returns == RESOURCE_LIST_PROTOCOL) {
            return Err(RouteResolutionError::invalid(
                "collection facets must return the Resource List protocol",
            ));
        }
        self.resolve_command_document(address, arguments, returns)
    }

    fn resolve_command_document(
        &self,
        address: &str,
        arguments: &[String],
        returns: &str,
    ) -> Result<ResolvedFacetDocument, RouteResolutionError> {
        self.exact_runnable_command(address)?;
        let output = self
            .query
            .query(address, arguments)
            .map_err(RouteResolutionError::Runtime)?;
        let value: serde_json::Value = serde_json::from_str(&output.stdout).map_err(|_| {
            RouteResolutionError::internal("facet resolver command returned invalid JSON")
        })?;
        validate_return_protocol(&value, returns)?;
        validate_resolver_exit(&value, returns, output.exit_code)?;
        let resource_list = if returns == RESOURCE_LIST_PROTOCOL {
            let resources: ResourceList = serde_json::from_value(value.clone()).map_err(|_| {
                RouteResolutionError::internal(
                    "facet resolver command returned an invalid Resource List",
                )
            })?;
            resources.validate().map_err(|_| {
                RouteResolutionError::internal(
                    "facet resolver command returned an invalid Resource List",
                )
            })?;
            Some(resources)
        } else {
            None
        };
        Ok(ResolvedFacetDocument {
            value,
            resource_list,
        })
    }

    fn exact_runnable_command(&self, address: &str) -> Result<&CommandNode, RouteResolutionError> {
        let mut matches = self.catalog.commands.iter().filter(|command| {
            command.address == address
                && !command.is_control()
                && command.runnable
                && command.alias_of.is_none()
        });
        let command = matches
            .next()
            .ok_or_else(|| RouteResolutionError::not_found("resolver command not found"))?;
        if matches.next().is_some() {
            return Err(RouteResolutionError::invalid(
                "resolver command address is ambiguous",
            ));
        }
        Ok(command)
    }
}

fn validate_resolver_exit(
    document: &serde_json::Value,
    returns: &str,
    exit_code: i32,
) -> Result<(), RouteResolutionError> {
    if returns != COMMAND_CHECK_PROTOCOL {
        return if exit_code == 0 {
            Ok(())
        } else {
            Err(RouteResolutionError::internal(format!(
                "facet resolver command exited with code {exit_code}"
            )))
        };
    }
    let ready = document
        .get("ready")
        .and_then(serde_json::Value::as_bool)
        .ok_or_else(|| {
            RouteResolutionError::internal("command-check resolver returned an invalid ready state")
        })?;
    if matches!((exit_code, ready), (0, true) | (1, false)) {
        Ok(())
    } else {
        Err(RouteResolutionError::internal(
            "command-check resolver exit code does not match document readiness",
        ))
    }
}

fn validate_return_protocol(
    document: &serde_json::Value,
    expected: &str,
) -> Result<(), RouteResolutionError> {
    let object = document.as_object().ok_or_else(|| {
        RouteResolutionError::internal("facet resolver command must return a JSON object")
    })?;
    let protocol = object.get("protocol").and_then(serde_json::Value::as_str);
    let schema = object.get("schema").and_then(serde_json::Value::as_str);
    if matches!((protocol, schema), (Some(actual), None) | (None, Some(actual)) if actual == expected)
    {
        Ok(())
    } else {
        Err(RouteResolutionError::internal(
            "facet resolver command returned the wrong protocol",
        ))
    }
}
