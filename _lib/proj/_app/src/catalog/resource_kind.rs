use std::collections::{BTreeMap, BTreeSet};

use crate::resource_kind::{
    ResourceFacetArgument, ResourceFacetArgumentBinding, ResourceFacetBinding,
    ResourceFacetResolver, ResourceFacetTemplate, ResourceKind,
};

use super::{
    CommandNode,
    declaration::{
        FacetArgumentDeclaration, FacetDeclaration, FacetResolverDeclaration,
        ResourceKindDeclaration,
    },
};

#[derive(Clone, Copy)]
struct ResolverCapability {
    runnable: bool,
    canonical: bool,
    control: bool,
}

impl ResolverCapability {
    fn web_runnable(self) -> bool {
        self.runnable && self.canonical && !self.control
    }
}

pub(super) fn resolve_resource_kinds(commands: &mut [CommandNode]) {
    let capabilities = commands
        .iter()
        .map(|command| {
            (
                command.address.clone(),
                ResolverCapability {
                    runnable: command.runnable,
                    canonical: command.alias_of.is_none(),
                    control: command.is_control(),
                },
            )
        })
        .collect::<BTreeMap<_, _>>();
    let mut owners = BTreeMap::<String, Vec<usize>>::new();
    for (index, command) in commands.iter().enumerate() {
        for declaration in &command.declared_resource_kinds {
            if let ResourceKindDeclaration::Definition { kind, .. } = declaration {
                owners.entry(kind.clone()).or_default().push(index);
            }
        }
    }

    for (kind, indexes) in owners.iter().filter(|(_, indexes)| indexes.len() > 1) {
        for index in indexes {
            append_diagnostic(
                &mut commands[*index],
                format!("Resource kind '{kind}' is declared by more than one provider"),
            );
        }
    }

    for index in 0..commands.len() {
        let declarations = commands[index].declared_resource_kinds.clone();
        for declaration in declarations {
            let ResourceKindDeclaration::Definition {
                kind,
                source,
                facets,
            } = declaration
            else {
                continue;
            };
            if owners.get(&kind).is_some_and(|indexes| indexes.len() > 1) {
                continue;
            }
            match resolve_resource_kind(kind, source, facets, &capabilities) {
                Ok(resource_kind) => commands[index].resource_kinds.push(resource_kind),
                Err(diagnostic) => append_diagnostic(&mut commands[index], diagnostic),
            }
        }
    }

    let definitions = commands
        .iter()
        .flat_map(|command| {
            command
                .resource_kinds
                .iter()
                .map(|kind| kind.source.clone())
        })
        .collect::<BTreeSet<_>>();
    for command in commands {
        let references = command
            .declared_resource_kinds
            .iter()
            .filter_map(|declaration| match declaration {
                ResourceKindDeclaration::Reference { source, target } => {
                    Some((source.clone(), target.clone()))
                }
                ResourceKindDeclaration::Definition { .. } => None,
            })
            .collect::<Vec<_>>();
        for (source, target) in references {
            if !definitions.contains(&target) {
                append_diagnostic(
                    command,
                    format!(
                        "Resource Kind ref on '{source}' must target one local definition; '{target}' is missing or is itself a ref"
                    ),
                );
            }
        }
    }
}

fn resolve_resource_kind(
    kind: String,
    source: swawkit_proj_protocol::FacetRoute,
    facets: Vec<FacetDeclaration>,
    capabilities: &BTreeMap<String, ResolverCapability>,
) -> Result<ResourceKind, String> {
    let facets = facets
        .into_iter()
        .map(|facet| resolve_resource_facet(facet, capabilities))
        .collect::<Result<Vec<_>, _>>()?;
    let resource_kind = ResourceKind {
        kind,
        source,
        facets,
    };
    resource_kind.validate()?;
    Ok(resource_kind)
}

fn resolve_resource_facet(
    declaration: FacetDeclaration,
    capabilities: &BTreeMap<String, ResolverCapability>,
) -> Result<ResourceFacetTemplate, String> {
    let Some(FacetResolverDeclaration::Invoke {
        address,
        arguments,
        accepts_tail,
        confirmation,
        returns,
    }) = declaration.resolver
    else {
        return Err(format!(
            "Resource Facet '{}' must declare a command resolver",
            declaration.id
        ));
    };
    let Some(capability) = capabilities.get(&address) else {
        return Err(format!(
            "Resource Facet '{}' references missing command '{}'",
            declaration.id, address
        ));
    };
    if !capability.web_runnable() {
        return Err(format!(
            "Resource Facet '{}' command '{}' is not an exact Web-runnable command",
            declaration.id, address
        ));
    }
    let arguments = arguments
        .into_iter()
        .map(|argument| match argument {
            FacetArgumentDeclaration::Literal(value) => ResourceFacetArgument::Literal(value),
            FacetArgumentDeclaration::ResourceSelector => {
                ResourceFacetArgument::Binding(ResourceFacetArgumentBinding {
                    bind: ResourceFacetBinding::ResourceSelector,
                })
            }
        })
        .collect();
    Ok(ResourceFacetTemplate {
        id: declaration.id,
        kind: declaration.kind,
        renderer: declaration.renderer,
        icon: declaration.icon,
        label: declaration.label,
        summary: declaration.summary,
        resolver: ResourceFacetResolver::Command {
            address,
            arguments,
            accepts_tail,
            confirmation,
            returns,
        },
        view: declaration.view,
    })
}

fn append_diagnostic(command: &mut CommandNode, diagnostic: String) {
    command.diagnostic = Some(match command.diagnostic.take() {
        Some(existing) => format!("{existing}; {diagnostic}"),
        None => diagnostic,
    });
}
