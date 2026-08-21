mod command_capability;
mod command_environment;
mod command_identity;
mod command_name;
mod dev_environment;
mod dev_settings;
mod digest;
mod execution_contract;
mod release;
mod resource_authoring;
mod resource_capabilities;
mod resource_list;
mod resource_route;
mod web_view;

pub use serde;
pub use serde_json;

pub use command_capability::{
    CommandProvision, CommandRequirement, MAX_COMMAND_PROVISIONS, MAX_COMMAND_REQUIREMENTS,
    validate_command_provisions, validate_command_requirements,
};
pub use command_environment::COMMAND_ENVIRONMENT_PROTOCOL;
pub use command_identity::{
    CommandIdentity, CommandSpace, MAX_COMMAND_ADDRESS_BYTES, command_data_root,
    native_command_root,
};
pub use command_name::{valid_command_segment, valid_module_namespace};
pub use dev_environment::{
    DEV_ENVIRONMENT_EXPORT_NAME, DEV_ENVIRONMENT_SCHEMA, DevEnvironmentExport,
    DevEnvironmentVariable, parse_dev_environment, validate_dev_environment,
};
pub use dev_settings::{
    DEV_SETTINGS_SCHEMA, DevArchiveToolSettings, DevMsvcSettings, DevRustSettings, DevSettings,
    dev_settings_input_revision, parse_dev_settings, validate_dev_settings,
};
pub use digest::{REVISION_PREFIX, RevisionBuilder, is_revision, is_sha256, revision, sha256_hex};
pub use execution_contract::{
    EXECUTION_CONTRACT_SCHEMA, ExecutionContract, ExecutionContractCommand, ExecutionSemantics,
};
pub use release::{
    COMMAND_EXECUTABLE_NAME, COMMAND_RELEASE_SCHEMA, CommandRelease, ExecutableArtifact,
    command_release_document, command_release_id, parse_command_release, validate_command_artifact,
    validate_command_release,
};
pub use resource_authoring::{
    FACET_EXECUTION_SCHEMA, FacetExecution, FacetExecutionArgument, FacetExecutionArgumentBinding,
    FacetExecutionBinding, FacetExecutionManifest, RESOURCE_FACET_SCHEMA, RESOURCE_KIND_SCHEMA,
    RESOURCE_SCHEMA, ResourceFacetKind, ResourceFacetManifest, ResourceFacetPresentation,
    ResourceKindManifest, ResourceLocalizedText, ResourceManifest, parse_facet_execution_manifest,
    parse_resource_facet_manifest, parse_resource_kind_manifest, parse_resource_manifest,
};
pub use resource_capabilities::{
    FACET_REQUIREMENTS_SCHEMA, FacetRequirement, FacetRequirementsManifest, MAX_FACET_REQUIREMENTS,
    MAX_RESOURCE_EXPORTS, RESOURCE_EXPORTS_SCHEMA, ResourceExport, ResourceExportsManifest,
    parse_facet_requirements_manifest, parse_resource_exports_manifest,
};
pub use resource_list::{
    MAX_RESOURCE_LIST_ITEMS, MAX_RESOURCE_LISTING_FACETS, RESOURCE_LIST_PROTOCOL, ResourceIdentity,
    ResourceList, ResourceListing, parse_resource_list,
};
pub use resource_route::{
    FacetRoute, MAX_RESOURCE_ROUTE_BYTES, MAX_RESOURCE_ROUTE_HOPS, ResourceHop, ResourceRoute,
    RouteTarget, command_resource_route, parse_route,
};
pub use web_view::{
    FACET_RESULT_RESOURCE, WEB_VIEW_BUNDLE_PROTOCOL, WEB_VIEW_SOURCE_SCHEMA, WebColumnView,
    WebColumnWidth, WebViewBody, WebViewBundle, WebViewSource, parse_web_view_bundle,
    parse_web_view_source, resolve_web_view,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProtocolError(String);

impl ProtocolError {
    pub fn new(message: impl Into<String>) -> Self {
        Self(message.into())
    }
}

impl std::fmt::Display for ProtocolError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for ProtocolError {}

pub type ProtocolResult<T> = Result<T, ProtocolError>;
