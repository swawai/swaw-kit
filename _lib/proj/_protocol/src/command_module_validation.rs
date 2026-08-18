use std::collections::BTreeSet;

use crate::{
    COMMAND_MODULE_SCHEMA, CommandModuleCommandSpace, CommandModuleExecution, CommandModuleFacet,
    CommandModuleFacetArgument, CommandModuleFacetBinding, CommandModuleFacetKind,
    CommandModuleFacetRenderer, CommandModuleFacetResolver, CommandModuleLocalizedText,
    CommandModuleManifest, CommandModuleSubjectKind, CommandModuleSubjectKindRef,
    CommandModuleSubjectRef, ProtocolError, ProtocolResult, valid_module_token,
    valid_provider_address, validate_command_address, validate_module_provisions,
    validate_module_requirements,
};

const SUBJECT_COLLECTION_PROTOCOL: &str = "swawkit.subject-collection/v3";
const MAX_FACETS: usize = 16;
const MAX_SUBJECT_KINDS: usize = 8;
const MAX_ARGUMENTS: usize = 32;
const MAX_ARGUMENT_LENGTH: usize = 4096;

#[derive(Clone, Copy)]
enum FacetScope {
    Command,
    Subject,
}

pub fn validate_command_module(manifest: &CommandModuleManifest) -> ProtocolResult<()> {
    if manifest.schema != COMMAND_MODULE_SCHEMA {
        return Err(ProtocolError::new(format!(
            "unsupported module contract schema '{}'; expected '{COMMAND_MODULE_SCHEMA}'",
            manifest.schema
        )));
    }
    validate_execution(manifest)?;
    validate_module_requirements(&manifest.requires)?;
    validate_module_provisions(&manifest.provides)?;
    validate_subject_kinds(&manifest.subject_kinds)?;
    validate_facets(&manifest.facets, FacetScope::Command)
}

fn validate_execution(manifest: &CommandModuleManifest) -> ProtocolResult<()> {
    match &manifest.execution {
        Some(
            CommandModuleExecution::Core { handler }
            | CommandModuleExecution::Toolchain { handler },
        ) => validate_text(handler, 128, "execution handler")?,
        Some(CommandModuleExecution::Runtime { product }) => {
            validate_text(product, 64, "Runtime Component product")?
        }
        Some(CommandModuleExecution::Delegate { owner }) => {
            validate_subject_ref(owner)?;
            let CommandModuleSubjectRef::Command {
                space: CommandModuleCommandSpace::Module,
                namespace: Some(namespace),
                address,
            } = owner
            else {
                return Err(ProtocolError::new(
                    "execution delegate owner must be a Module command",
                ));
            };
            validate_command_address(address)?;
            if address.split('/').next() != Some(namespace.as_str()) {
                return Err(ProtocolError::new(
                    "execution delegate owner namespace does not match its address",
                ));
            }
        }
        Some(CommandModuleExecution::Native) | None => {}
    }
    if matches!(
        manifest.execution,
        Some(CommandModuleExecution::Core { .. })
    ) && !manifest.requires.is_empty()
    {
        return Err(ProtocolError::new(
            "Core execution cannot declare module requirements",
        ));
    }
    Ok(())
}

fn validate_subject_kinds(values: &[CommandModuleSubjectKind]) -> ProtocolResult<()> {
    if values.len() > MAX_SUBJECT_KINDS {
        return Err(ProtocolError::new(format!(
            "module subjectKinds cannot contain more than {MAX_SUBJECT_KINDS} items"
        )));
    }
    let mut seen = BTreeSet::new();
    for value in values {
        if !valid_module_token(&value.kind) || !seen.insert(value.kind.as_str()) {
            return Err(ProtocolError::new(
                "invalid or duplicate module subject kind",
            ));
        }
        if value.facets.is_empty() {
            return Err(ProtocolError::new(
                "module subject kind must declare at least one facet",
            ));
        }
        validate_facets(&value.facets, FacetScope::Subject)?;
    }
    Ok(())
}

fn validate_facets(values: &[CommandModuleFacet], scope: FacetScope) -> ProtocolResult<()> {
    if values.len() > MAX_FACETS {
        return Err(ProtocolError::new(format!(
            "module facets cannot contain more than {MAX_FACETS} items"
        )));
    }
    let mut seen = BTreeSet::new();
    for value in values {
        if !valid_module_token(&value.id) || !seen.insert(value.id.as_str()) {
            return Err(ProtocolError::new("invalid or duplicate module facet id"));
        }
        validate_text(&value.icon, 8, "facet icon")?;
        validate_localized_text(&value.label, 64, "facet label")?;
        validate_localized_text(&value.summary, 200, "facet summary")?;
        validate_facet_shape(value, scope)?;
    }
    Ok(())
}

fn validate_facet_shape(facet: &CommandModuleFacet, scope: FacetScope) -> ProtocolResult<()> {
    if !matches!(
        (facet.kind, facet.renderer),
        (
            CommandModuleFacetKind::Collection,
            CommandModuleFacetRenderer::Collection
        ) | (
            CommandModuleFacetKind::Operation,
            CommandModuleFacetRenderer::Run
        ) | (
            CommandModuleFacetKind::Projection,
            CommandModuleFacetRenderer::Overview
        )
    ) {
        return Err(ProtocolError::new(
            "module facet kind and renderer are incompatible",
        ));
    }
    match scope {
        FacetScope::Command if facet.kind == CommandModuleFacetKind::Collection => {
            let Some(reference) = &facet.subject_kind else {
                return Err(ProtocolError::new(
                    "collection facet must declare one subjectKind reference",
                ));
            };
            validate_subject_kind_ref(reference)?;
        }
        FacetScope::Command if facet.subject_kind.is_some() => {
            return Err(ProtocolError::new(
                "only a collection facet may declare subjectKind",
            ));
        }
        FacetScope::Subject if facet.subject_kind.is_some() => {
            return Err(ProtocolError::new(
                "subject facet cannot declare subjectKind",
            ));
        }
        FacetScope::Subject if facet.kind == CommandModuleFacetKind::Collection => {
            return Err(ProtocolError::new(
                "subject facet cannot expose a nested collection",
            ));
        }
        _ => {}
    }

    let Some(CommandModuleFacetResolver::Command {
        address,
        arguments,
        accepts_tail,
        confirmation,
        returns,
    }) = &facet.resolver
    else {
        return Err(ProtocolError::new(
            "module facet must declare a command resolver",
        ));
    };
    validate_resolver(
        facet,
        scope,
        address,
        arguments,
        *accepts_tail,
        confirmation.as_deref(),
        returns.as_deref(),
    )
}

#[allow(clippy::too_many_arguments)]
fn validate_resolver(
    facet: &CommandModuleFacet,
    scope: FacetScope,
    address: &str,
    arguments: &[CommandModuleFacetArgument],
    accepts_tail: bool,
    confirmation: Option<&str>,
    returns: Option<&str>,
) -> ProtocolResult<()> {
    if !valid_provider_address(address) {
        return Err(ProtocolError::new("invalid module facet command address"));
    }
    if arguments.len() > MAX_ARGUMENTS
        || arguments.iter().any(|argument| {
            matches!(argument, CommandModuleFacetArgument::Literal(value)
                if value.len() > MAX_ARGUMENT_LENGTH || value.contains('\0'))
        })
    {
        return Err(ProtocolError::new(
            "module facet arguments exceed their limits",
        ));
    }
    let valid_binding = |binding| match scope {
        FacetScope::Command => binding == CommandModuleFacetBinding::CommandAddress,
        FacetScope::Subject => binding == CommandModuleFacetBinding::SubjectId,
    };
    if arguments.iter().any(|argument| {
        matches!(argument, CommandModuleFacetArgument::Binding(binding)
            if !valid_binding(binding.bind))
    }) {
        return Err(ProtocolError::new(
            "module facet binding is outside its Subject scope",
        ));
    }
    if let Some(value) = confirmation {
        validate_text(value, 500, "facet confirmation")?;
    }
    if accepts_tail && confirmation.is_some() {
        return Err(ProtocolError::new(
            "module facet cannot combine tail arguments with confirmation",
        ));
    }
    match facet.kind {
        CommandModuleFacetKind::Collection if returns != Some(SUBJECT_COLLECTION_PROTOCOL) => {
            return Err(ProtocolError::new(format!(
                "collection facet must return {SUBJECT_COLLECTION_PROTOCOL}"
            )));
        }
        CommandModuleFacetKind::Projection
            if returns.is_none() || returns == Some(SUBJECT_COLLECTION_PROTOCOL) =>
        {
            return Err(ProtocolError::new(
                "projection facet must declare a non-collection returned protocol",
            ));
        }
        CommandModuleFacetKind::Operation if returns.is_some() => {
            return Err(ProtocolError::new(
                "operation facet cannot declare a returned protocol",
            ));
        }
        CommandModuleFacetKind::Collection | CommandModuleFacetKind::Projection
            if accepts_tail || confirmation.is_some() =>
        {
            return Err(ProtocolError::new(
                "document facet must use exact arguments without confirmation",
            ));
        }
        _ => {}
    }
    if let Some(protocol) = returns {
        validate_text(protocol, 128, "facet returned protocol")?;
    }
    Ok(())
}

fn validate_subject_kind_ref(reference: &CommandModuleSubjectKindRef) -> ProtocolResult<()> {
    if !valid_module_token(&reference.kind) {
        return Err(ProtocolError::new("invalid Subject kind reference"));
    }
    if !matches!(reference.provider, CommandModuleSubjectRef::Command { .. }) {
        return Err(ProtocolError::new(
            "Subject kind provider must be a command Subject",
        ));
    }
    validate_subject_ref(&reference.provider)
}

fn validate_subject_ref(reference: &CommandModuleSubjectRef) -> ProtocolResult<()> {
    match reference {
        CommandModuleSubjectRef::Command {
            space,
            namespace,
            address,
        } => {
            let valid_identity = match space {
                CommandModuleCommandSpace::System => {
                    namespace.is_none() && (address.is_empty() || address.starts_with('.'))
                }
                CommandModuleCommandSpace::Module => namespace.as_deref().is_some_and(|value| {
                    address == value
                        || address
                            .strip_prefix(value)
                            .is_some_and(|tail| tail.starts_with('/'))
                }),
            };
            if address.contains('\0') || address.len() > 256 || !valid_identity {
                return Err(ProtocolError::new("invalid command Subject reference"));
            }
        }
        CommandModuleSubjectRef::Instance { kind, id } => {
            if !valid_module_token(kind) || !valid_instance_id(id) {
                return Err(ProtocolError::new("invalid instance Subject reference"));
            }
        }
    }
    Ok(())
}

fn valid_instance_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value.bytes().enumerate().all(|(index, byte)| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || (index > 0 && byte == b'-')
        })
}

fn validate_localized_text(
    value: &CommandModuleLocalizedText,
    max: usize,
    field: &str,
) -> ProtocolResult<()> {
    validate_text(&value.zh_cn, max, &format!("{field}.zh-CN"))?;
    validate_text(&value.en, max, &format!("{field}.en"))
}

fn validate_text(value: &str, max: usize, field: &str) -> ProtocolResult<()> {
    if value.is_empty() || value.trim() != value || value.chars().count() > max {
        Err(ProtocolError::new(format!(
            "{field} must contain 1 to {max} trimmed characters"
        )))
    } else {
        Ok(())
    }
}
