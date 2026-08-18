use serde::Serialize;

use crate::{
    facet::{FacetKind, FacetRenderer},
    subject::SubjectRef,
    subject_kind::SubjectKindRef,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ModuleFacet {
    pub id: String,
    pub kind: FacetKind,
    pub renderer: FacetRenderer,
    pub icon: String,
    pub label: String,
    pub summary: String,
    pub subject_kind: Option<SubjectKindRef>,
    pub resolver: Option<ModuleFacetResolver>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ModuleSubjectKind {
    pub kind: String,
    pub facets: Vec<ModuleFacet>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ModuleFacetResolver {
    Command {
        address: String,
        arguments: Vec<ModuleFacetArgument>,
        accepts_tail: bool,
        confirmation: Option<String>,
        returns: Option<String>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum ModuleExecution {
    Core { handler: String },
    Toolchain { handler: String },
    Runtime { product: String },
    Native,
    Delegate { owner: SubjectRef },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ModuleFacetArgument {
    Literal(String),
    Binding(ModuleFacetArgumentBinding),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ModuleFacetArgumentBinding {
    pub bind: ModuleFacetBinding,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ModuleFacetBinding {
    CommandAddress,
    SubjectId,
}
