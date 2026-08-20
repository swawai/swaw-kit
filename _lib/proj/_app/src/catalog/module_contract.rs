use std::fs;
use std::io;
use std::path::Path;

use serde::Serialize;
pub use swawkit_proj_protocol::{
    COMMAND_MODULE_SCHEMA as MODULE_CONTRACT_PROTOCOL, ModuleProvision, ModuleRequirement,
};
use swawkit_proj_protocol::{
    CommandModuleExecution as WireExecution, CommandModuleFacet as WireFacet,
    CommandModuleFacetArgument as WireFacetArgument, CommandModuleFacetBinding as WireFacetBinding,
    CommandModuleFacetKind as WireFacetKind, CommandModuleFacetRenderer as WireFacetRenderer,
    CommandModuleFacetResolver as WireFacetResolver,
    CommandModuleLocalizedText as WireLocalizedText,
    CommandModuleSubjectKindRef as WireSubjectKindRef, CommandModuleSubjectRef as WireSubjectRef,
    parse_command_module,
};

use crate::{
    entry_config::EntryLanguage,
    facet::{FacetKind, FacetRenderer},
    subject::SubjectRef,
    subject_kind::SubjectKindRef,
};

use super::{filesystem::directory_files, invalid_data};

mod declaration;

pub use declaration::ModuleExecution;
pub(crate) use declaration::{
    ModuleFacet, ModuleFacetArgument, ModuleFacetArgumentBinding, ModuleFacetBinding,
    ModuleFacetResolver, ModuleSubjectKind,
};

pub(crate) const MODULE_CONTRACT_FILE: &str = "swawkit.module.json";

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandModuleContract {
    pub schema: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub execution: Option<ModuleExecution>,
    pub requires: Vec<ModuleRequirement>,
    pub provides: Vec<ModuleProvision>,
    #[serde(skip)]
    pub(crate) facets: Vec<ModuleFacet>,
    #[serde(skip)]
    pub(crate) subject_kinds: Vec<ModuleSubjectKind>,
}

pub(super) fn read_local_module_contract(
    command_directory: &Path,
    language: EntryLanguage,
) -> io::Result<Option<CommandModuleContract>> {
    let files = directory_files(command_directory)?;
    let matches = files
        .iter()
        .filter(|file| file.name.eq_ignore_ascii_case(MODULE_CONTRACT_FILE))
        .collect::<Vec<_>>();
    if matches.len() > 1 {
        return invalid_data(format!(
            "module contract file name collision below '{}': {}",
            command_directory.display(),
            matches
                .iter()
                .map(|file| file.name.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }
    let Some(file) = matches.first() else {
        return Ok(None);
    };
    if file.name != MODULE_CONTRACT_FILE {
        return invalid_data(format!(
            "non-canonical module contract file '{}'; expected '{MODULE_CONTRACT_FILE}'",
            file.name
        ));
    }
    if file.reparse_point {
        return invalid_data(format!(
            "module contract file cannot be a reparse point: {}",
            file.path.display()
        ));
    }

    let content = fs::read(&file.path)?;
    let manifest = parse_command_module(&content).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "invalid module contract manifest '{}': {error}",
                file.path.display()
            ),
        )
    })?;

    let facets = manifest
        .facets
        .into_iter()
        .map(|facet| project_facet(facet, language))
        .collect();
    let subject_kinds = manifest
        .subject_kinds
        .into_iter()
        .map(|subject_kind| ModuleSubjectKind {
            kind: subject_kind.kind,
            facets: subject_kind
                .facets
                .into_iter()
                .map(|facet| project_facet(facet, language))
                .collect(),
        })
        .collect();
    Ok(Some(CommandModuleContract {
        schema: manifest.schema,
        execution: manifest.execution.map(project_execution),
        requires: manifest.requires,
        provides: manifest.provides,
        facets,
        subject_kinds,
    }))
}

fn project_execution(execution: WireExecution) -> ModuleExecution {
    match execution {
        WireExecution::Core { handler } => ModuleExecution::Core { handler },
        WireExecution::Runtime { product } => ModuleExecution::Runtime { product },
        WireExecution::Native => ModuleExecution::Native,
        WireExecution::Delegate { owner } => ModuleExecution::Delegate {
            owner: project_subject_ref(owner),
        },
    }
}

fn project_facet(facet: WireFacet, language: EntryLanguage) -> ModuleFacet {
    ModuleFacet {
        id: facet.id,
        kind: project_facet_kind(facet.kind),
        renderer: project_facet_renderer(facet.renderer),
        icon: facet.icon,
        label: localized(facet.label, language),
        summary: localized(facet.summary, language),
        subject_kind: facet.subject_kind.map(project_subject_kind_ref),
        resolver: facet.resolver.map(|resolver| match resolver {
            WireFacetResolver::Command {
                address,
                arguments,
                accepts_tail,
                confirmation,
                returns,
            } => ModuleFacetResolver::Command {
                address,
                arguments: arguments.into_iter().map(project_argument).collect(),
                accepts_tail,
                confirmation,
                returns,
            },
        }),
    }
}

fn project_argument(argument: WireFacetArgument) -> ModuleFacetArgument {
    match argument {
        WireFacetArgument::Literal(value) => ModuleFacetArgument::Literal(value),
        WireFacetArgument::Binding(binding) => {
            ModuleFacetArgument::Binding(ModuleFacetArgumentBinding {
                bind: match binding.bind {
                    WireFacetBinding::CommandAddress => ModuleFacetBinding::CommandAddress,
                    WireFacetBinding::SubjectId => ModuleFacetBinding::SubjectId,
                },
            })
        }
    }
}

fn project_facet_kind(kind: WireFacetKind) -> FacetKind {
    match kind {
        WireFacetKind::Collection => FacetKind::Collection,
        WireFacetKind::Operation => FacetKind::Operation,
        WireFacetKind::Projection => FacetKind::Projection,
    }
}

fn project_facet_renderer(renderer: WireFacetRenderer) -> FacetRenderer {
    match renderer {
        WireFacetRenderer::Collection => FacetRenderer::Collection,
        WireFacetRenderer::Edit => FacetRenderer::Edit,
        WireFacetRenderer::Help => FacetRenderer::Help,
        WireFacetRenderer::Overview => FacetRenderer::Overview,
        WireFacetRenderer::Run => FacetRenderer::Run,
    }
}

fn project_subject_kind_ref(reference: WireSubjectKindRef) -> SubjectKindRef {
    SubjectKindRef {
        kind: reference.kind,
        provider: project_subject_ref(reference.provider),
    }
}

fn project_subject_ref(reference: WireSubjectRef) -> SubjectRef {
    match reference {
        WireSubjectRef::Command {
            space,
            namespace,
            address,
        } => SubjectRef::Command {
            space,
            namespace,
            address,
        },
        WireSubjectRef::Instance { kind, id } => SubjectRef::Instance { kind, id },
    }
}

fn localized(value: WireLocalizedText, language: EntryLanguage) -> String {
    match language {
        EntryLanguage::ZhCn => value.zh_cn,
        EntryLanguage::En => value.en,
    }
}
