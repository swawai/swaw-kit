use swawkit_proj_protocol::{FacetRoute, WebViewSource};

use crate::facet::{FacetKind, FacetRenderer};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct FacetDeclaration {
    pub id: String,
    pub kind: FacetKind,
    pub renderer: FacetRenderer,
    pub icon: String,
    pub label: String,
    pub summary: String,
    pub resource_kind: Option<FacetRoute>,
    pub resolver: Option<FacetResolverDeclaration>,
    pub view: Option<WebViewSource>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ResourceKindDeclaration {
    Definition {
        kind: String,
        source: FacetRoute,
        facets: Vec<FacetDeclaration>,
    },
    Reference {
        source: FacetRoute,
        target: FacetRoute,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum FacetResolverDeclaration {
    Catalog {
        relation: String,
    },
    Invoke {
        address: String,
        arguments: Vec<FacetArgumentDeclaration>,
        accepts_tail: bool,
        confirmation: Option<String>,
        returns: Option<String>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum FacetArgumentDeclaration {
    Literal(String),
    ResourceSelector,
}
