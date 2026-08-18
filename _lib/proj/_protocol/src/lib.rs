mod command_module;
mod command_module_validation;
mod digest;
mod execution_contract;
mod module_contract;
mod release;

pub use serde;
pub use serde_json;

pub use command_module::{
    CommandModuleCommandSpace, CommandModuleExecution, CommandModuleFacet,
    CommandModuleFacetArgument, CommandModuleFacetArgumentBinding, CommandModuleFacetBinding,
    CommandModuleFacetKind, CommandModuleFacetRenderer, CommandModuleFacetResolver,
    CommandModuleLocalizedText, CommandModuleManifest, CommandModuleSubjectKind,
    CommandModuleSubjectKindRef, CommandModuleSubjectRef, parse_command_module,
};
pub use command_module_validation::validate_command_module;
pub use digest::{REVISION_PREFIX, RevisionBuilder, is_revision, is_sha256, revision, sha256_hex};
pub use execution_contract::{ExecutionContract, ExecutionContractCommand, ExecutionSemantics};
pub use module_contract::{
    COMMAND_MODULE_SCHEMA, MAX_MODULE_PROVISIONS, MAX_MODULE_REQUIREMENTS, ModuleProvision,
    ModuleRequirement, valid_command_segment, valid_module_contract, valid_module_namespace,
    valid_module_token, valid_provider_address, validate_command_address,
    validate_module_provisions, validate_module_requirements,
};
pub use release::{
    COMMAND_EXECUTABLE_NAME, COMMAND_RELEASE_SCHEMA, CommandRelease, ExecutableArtifact,
    command_release_document, command_release_id, parse_command_release, validate_command_artifact,
    validate_command_release,
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
