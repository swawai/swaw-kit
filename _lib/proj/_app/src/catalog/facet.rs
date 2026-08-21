use std::collections::{BTreeMap, BTreeSet};

use crate::{
    entry_config::EntryLanguage,
    facet::{Facet, FacetResolver},
    resource_kind::ResourceKindRef,
};

use super::{
    CommandNode,
    declaration::{FacetArgumentDeclaration, FacetDeclaration, FacetResolverDeclaration},
};

mod defaults;

use defaults::{default_facets, subcommands_facet};

const HELP_ADDRESS: &str = ".help";
const CHECK_ADDRESS: &str = ".check";

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

pub(super) fn resolve_command_facets(commands: &mut [CommandNode], language: EntryLanguage) {
    let parents = commands
        .iter()
        .filter_map(|command| command.parent.clone())
        .collect::<BTreeSet<_>>();
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
    let help_available = capabilities
        .get(HELP_ADDRESS)
        .is_some_and(|capability| capability.web_runnable());
    let check_available = capabilities
        .get(CHECK_ADDRESS)
        .is_some_and(|capability| capability.web_runnable());
    let resource_kind_providers = commands
        .iter()
        .flat_map(|command| {
            command.resource_kinds.iter().map(|resource_kind| {
                (
                    resource_kind.source.clone(),
                    ResourceKindRef {
                        source: resource_kind.source.clone(),
                    },
                )
            })
        })
        .collect::<BTreeMap<_, _>>();
    for command in commands {
        let subcommands = parents
            .contains(&command.address)
            .then(|| subcommands_facet(language));
        let defaults = default_facets(command, language, help_available, check_available);
        let core_ids = subcommands
            .iter()
            .chain(defaults.iter())
            .map(|facet| facet.id.clone())
            .collect::<BTreeSet<_>>();
        let declarations = command.declared_facets.clone();
        let declaration_order = declarations
            .iter()
            .map(|facet| facet.id.clone())
            .collect::<Vec<_>>();
        let declared_ids = declaration_order.iter().cloned().collect::<BTreeSet<_>>();
        let mut declared = BTreeMap::new();
        for declaration in declarations {
            let id = declaration.id.clone();
            match resolve_declared_facet(declaration, &capabilities, &resource_kind_providers) {
                Ok(facet) => {
                    declared.insert(id, facet);
                }
                Err(diagnostic) => append_diagnostic(command, diagnostic),
            }
        }

        let mut facets = Vec::new();
        if let Some(subcommands) = subcommands {
            append_core_facet(&mut facets, subcommands, &declared_ids, &mut declared);
        }
        for id in declaration_order
            .iter()
            .filter(|id| !core_ids.contains(*id))
        {
            if let Some(facet) = declared.remove(id) {
                facets.push(facet);
            }
        }
        for facet in defaults {
            append_core_facet(&mut facets, facet, &declared_ids, &mut declared);
        }
        command.facets = facets;
    }
}

fn append_core_facet(
    facets: &mut Vec<Facet>,
    core: Facet,
    declared_ids: &BTreeSet<String>,
    declared: &mut BTreeMap<String, Facet>,
) {
    if let Some(replacement) = declared.remove(&core.id) {
        facets.push(replacement);
    } else if !declared_ids.contains(&core.id) {
        facets.push(core);
    }
}

fn resolve_declared_facet(
    declaration: FacetDeclaration,
    capabilities: &BTreeMap<String, ResolverCapability>,
    resource_kind_providers: &BTreeMap<swawkit_proj_protocol::FacetRoute, ResourceKindRef>,
) -> Result<Facet, String> {
    let resource_kind = declaration
        .resource_kind
        .as_ref()
        .map(|source| {
            resource_kind_providers.get(source).cloned().ok_or_else(|| {
                format!(
                    "facet '{}' references unavailable Resource Kind definition '{}'",
                    declaration.id, source
                )
            })
        })
        .transpose()?;
    let resolver = match declaration.resolver {
        None => None,
        Some(FacetResolverDeclaration::Catalog { relation }) => {
            Some(FacetResolver::Catalog { relation })
        }
        Some(FacetResolverDeclaration::Invoke {
            address,
            arguments,
            accepts_tail,
            confirmation,
            returns,
        }) => {
            let Some(capability) = capabilities.get(&address) else {
                return Err(format!(
                    "facet '{}' references missing command '{}'",
                    declaration.id, address
                ));
            };
            if !capability.web_runnable() {
                return Err(format!(
                    "facet '{}' command '{}' is not an exact Web-runnable command",
                    declaration.id, address
                ));
            }
            let arguments = arguments
                .into_iter()
                .map(|argument| match argument {
                    FacetArgumentDeclaration::Literal(value) => value,
                    FacetArgumentDeclaration::ResourceSelector => {
                        unreachable!("Resource Loader rejects selector bindings in command Facets")
                    }
                })
                .collect();
            Some(FacetResolver::Command {
                address,
                arguments,
                accepts_tail,
                confirmation,
                returns,
            })
        }
    };
    Ok(Facet {
        id: declaration.id,
        kind: declaration.kind,
        renderer: declaration.renderer,
        icon: declaration.icon,
        label: declaration.label,
        summary: declaration.summary,
        resource_kind,
        resolver,
        view: declaration.view,
    })
}

fn append_diagnostic(command: &mut CommandNode, diagnostic: String) {
    command.diagnostic = Some(match command.diagnostic.take() {
        Some(existing) => format!("{existing}; {diagnostic}"),
        None => diagnostic,
    });
}
