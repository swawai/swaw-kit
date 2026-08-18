use serde::{Deserialize, Serialize};

use crate::{CommandSpace, ModuleProvision, ModuleRequirement, ProtocolError, ProtocolResult};

use super::command_module_validation::validate_command_module;

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CommandModuleManifest {
    pub schema: String,
    #[serde(default)]
    pub execution: Option<CommandModuleExecution>,
    #[serde(default)]
    pub requires: Vec<ModuleRequirement>,
    #[serde(default)]
    pub provides: Vec<ModuleProvision>,
    #[serde(default)]
    pub facets: Vec<CommandModuleFacet>,
    #[serde(default)]
    pub subject_kinds: Vec<CommandModuleSubjectKind>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "lowercase", deny_unknown_fields)]
pub enum CommandModuleExecution {
    Core { handler: String },
    Toolchain { handler: String },
    Runtime { product: String },
    Native,
    Delegate { owner: CommandModuleSubjectRef },
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CommandModuleFacet {
    pub id: String,
    pub kind: CommandModuleFacetKind,
    pub renderer: CommandModuleFacetRenderer,
    pub icon: String,
    pub label: CommandModuleLocalizedText,
    pub summary: CommandModuleLocalizedText,
    #[serde(default)]
    pub subject_kind: Option<CommandModuleSubjectKindRef>,
    #[serde(default)]
    pub resolver: Option<CommandModuleFacetResolver>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CommandModuleSubjectKind {
    pub kind: String,
    pub facets: Vec<CommandModuleFacet>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "lowercase", deny_unknown_fields)]
pub enum CommandModuleFacetResolver {
    Command {
        address: String,
        #[serde(default)]
        arguments: Vec<CommandModuleFacetArgument>,
        #[serde(rename = "acceptsTail", default)]
        accepts_tail: bool,
        #[serde(default)]
        confirmation: Option<String>,
        #[serde(default)]
        returns: Option<String>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(untagged)]
pub enum CommandModuleFacetArgument {
    Literal(String),
    Binding(CommandModuleFacetArgumentBinding),
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct CommandModuleFacetArgumentBinding {
    pub bind: CommandModuleFacetBinding,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum CommandModuleFacetBinding {
    CommandAddress,
    #[serde(rename = "subject.id")]
    SubjectId,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum CommandModuleFacetKind {
    Collection,
    Operation,
    Projection,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum CommandModuleFacetRenderer {
    Collection,
    Edit,
    Help,
    Overview,
    Run,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct CommandModuleLocalizedText {
    #[serde(rename = "zh-CN")]
    pub zh_cn: String,
    pub en: String,
}

pub type CommandModuleCommandSpace = CommandSpace;

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "lowercase", deny_unknown_fields)]
pub enum CommandModuleSubjectRef {
    Command {
        space: CommandModuleCommandSpace,
        #[serde(default)]
        namespace: Option<String>,
        address: String,
    },
    Instance {
        kind: String,
        id: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CommandModuleSubjectKindRef {
    pub kind: String,
    pub provider: CommandModuleSubjectRef,
}

pub fn parse_command_module(bytes: &[u8]) -> ProtocolResult<CommandModuleManifest> {
    let manifest = serde_json::from_slice(bytes).map_err(|error| {
        ProtocolError::new(format!("invalid command Module manifest JSON: {error}"))
    })?;
    validate_command_module(&manifest)?;
    Ok(manifest)
}
