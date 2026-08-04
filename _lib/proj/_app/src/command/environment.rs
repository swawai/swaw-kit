use std::collections::BTreeMap;
use std::ffi::{OsStr, OsString};
use std::path::PathBuf;
use std::process::Command;

use crate::context::EntryContext;

use super::{GuardScope, ResolvedCommand};

const OPTIONAL_ENVIRONMENT: [&str; 3] = [
    "SWAWKIT_GUARD_SCOPE",
    "SWAWKIT_INTERNAL_RUNTIME_WORKING_DIR",
    "SWAWKIT_HELP_TARGET_ADDRESS",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandExecutionContext {
    pub proj_home: PathBuf,
    pub kernel_root: PathBuf,
    pub project_root: PathBuf,
    pub action_root: PathBuf,
    pub data_root: PathBuf,
    pub entry_name: String,
    pub entry_file: PathBuf,
    pub invocation_directory: PathBuf,
}

impl CommandExecutionContext {
    pub fn new(entry: &EntryContext, data_root: impl Into<PathBuf>) -> Self {
        Self {
            proj_home: entry.proj_home.clone(),
            kernel_root: entry.kernel_root(),
            project_root: entry.project_root.clone(),
            action_root: entry.action_root.clone(),
            data_root: data_root.into(),
            entry_name: entry.entry_name.clone(),
            entry_file: entry.entry_file.clone(),
            invocation_directory: entry.invocation_directory.clone(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ExecutionPhase {
    Run,
    Guard(GuardScope),
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct ProcessEnvironment {
    values: BTreeMap<OsString, Option<OsString>>,
}

impl ProcessEnvironment {
    pub(crate) fn for_command(
        context: &CommandExecutionContext,
        protocol_command: &ResolvedCommand,
        phase: ExecutionPhase,
        help_target_address: Option<&str>,
    ) -> Self {
        let mut environment = Self::default();
        for name in OPTIONAL_ENVIRONMENT {
            environment.remove(name);
        }
        environment.set("SWAWKIT_COMMAND_PROTOCOL", "1");
        environment.set(
            "SWAWKIT_COMMAND_PHASE",
            match phase {
                ExecutionPhase::Run => "run",
                ExecutionPhase::Guard(_) => "guard",
            },
        );
        environment.set("SWAWKIT_COMMAND_ADDRESS", &protocol_command.address);
        environment.set("SWAWKIT_COMMAND_DIR", &protocol_command.directory);
        if let ExecutionPhase::Guard(scope) = phase {
            environment.set("SWAWKIT_GUARD_SCOPE", scope.as_str());
        }
        if let Some(target) = help_target_address {
            environment.set("SWAWKIT_HELP_TARGET_ADDRESS", target);
        }
        environment.set("SWAWKIT_INVOCATION_DIR", &context.invocation_directory);
        environment.set("SWAWKIT_PROJ_PROTOCOL", "1");
        environment.set("SWAWKIT_PROJ_HOME", &context.proj_home);
        environment.set("SWAWKIT_PROJ_DIR", &context.project_root);
        environment.set("SWAWKIT_PROJ_ACTION_ROOT", &context.action_root);
        environment.set("SWAWKIT_PROJ_DATA_ROOT", &context.data_root);
        environment.set("SWAWKIT_PROJ_ENTRY_COMMAND", &context.entry_name);
        environment.set("SWAWKIT_PROJ_ENTRY_FILE", &context.entry_file);
        environment
    }

    fn set(&mut self, name: impl Into<OsString>, value: impl AsRef<OsStr>) {
        self.values
            .insert(name.into(), Some(value.as_ref().to_os_string()));
    }

    fn remove(&mut self, name: impl Into<OsString>) {
        self.values.insert(name.into(), None);
    }

    pub(crate) fn apply(&self, command: &mut Command) {
        for (name, value) in &self.values {
            match value {
                Some(value) => {
                    command.env(name, value);
                }
                None => {
                    command.env_remove(name);
                }
            }
        }
    }

    #[cfg(test)]
    pub(crate) fn value(&self, name: &str) -> Option<Option<&OsStr>> {
        self.values
            .get(OsStr::new(name))
            .map(|value| value.as_deref())
    }
}
