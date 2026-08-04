use std::collections::BTreeMap;
use std::ffi::{OsStr, OsString};
use std::path::PathBuf;
use std::process::Command;

use crate::{
    context::EntryContext,
    profile::{EntryProfile, EntryProfileRecord},
};

use super::{GuardScope, ResolvedCommand};

const OPTIONAL_ENVIRONMENT: [&str; 3] = [
    "SWAWKIT_PROJ_GUARD_SCOPE",
    "SWAWKIT_PROJ_INTERNAL_RUNTIME_WORKING_DIR",
    "SWAWKIT_PROJ_HELP_TARGET_ADDRESS",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandExecutionContext {
    pub swawkit_home: PathBuf,
    pub kernel_root: PathBuf,
    pub target_project_root: PathBuf,
    pub action_root: PathBuf,
    pub data_root: PathBuf,
    pub entry_name: String,
    pub entry_file: PathBuf,
    pub invocation_directory: PathBuf,
    pub profile: EntryProfileRecord,
}

impl CommandExecutionContext {
    pub fn new(
        entry: &EntryContext,
        profile: &EntryProfile,
        data_root: impl Into<PathBuf>,
    ) -> Self {
        let binding = profile.binding();
        Self {
            swawkit_home: entry.swawkit_home.clone(),
            kernel_root: entry.kernel_root(),
            target_project_root: binding.target_project_root().to_path_buf(),
            action_root: binding.action_root(),
            data_root: data_root.into(),
            entry_name: entry.entry_name.clone(),
            entry_file: entry.entry_file.clone(),
            invocation_directory: entry.invocation_directory.clone(),
            profile: profile.record().clone(),
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
        environment.set("SWAWKIT_PROJ_COMMAND_PROTOCOL", "1");
        environment.set(
            "SWAWKIT_PROJ_COMMAND_PHASE",
            match phase {
                ExecutionPhase::Run => "run",
                ExecutionPhase::Guard(_) => "guard",
            },
        );
        environment.set("SWAWKIT_PROJ_COMMAND_ADDRESS", &protocol_command.address);
        environment.set("SWAWKIT_PROJ_COMMAND_DIR", &protocol_command.directory);
        if let ExecutionPhase::Guard(scope) = phase {
            environment.set("SWAWKIT_PROJ_GUARD_SCOPE", scope.as_str());
        }
        if let Some(target) = help_target_address {
            environment.set("SWAWKIT_PROJ_HELP_TARGET_ADDRESS", target);
        }
        environment.set("SWAWKIT_PROJ_INVOCATION_DIR", &context.invocation_directory);
        environment.set("SWAWKIT_PROJ_PROTOCOL", "1");
        environment.set("SWAWKIT_HOME", &context.swawkit_home);
        environment.set(
            "SWAWKIT_PROJ_TARGET_PROJECT_ROOT",
            &context.target_project_root,
        );
        environment.set("SWAWKIT_PROJ_ACTION_ROOT", &context.action_root);
        environment.set("SWAWKIT_PROJ_DATA_ROOT", &context.data_root);
        environment.set("SWAWKIT_PROJ_ENTRY_COMMAND", &context.entry_name);
        environment.set("SWAWKIT_PROJ_ENTRY_FILE", &context.entry_file);
        environment.apply_profile(&context.profile);
        environment
    }

    fn apply_profile(&mut self, profile: &EntryProfileRecord) {
        let preferences = &profile.preferences;
        let development = &profile.development;
        self.set("SWAWKIT_PROJ_DEFAULT_SHELL", &preferences.default_shell);
        self.set("SWAWKIT_PROJ_DEFAULT_IDE", &preferences.default_ide);
        self.set_optional("SWAWKIT_PROJ_HELP_LANG", &preferences.help_language);

        self.set("SWAWKIT_PROJ_BUN_MODE", &development.bun.mode);
        self.set("SWAWKIT_PROJ_BUN_VERSION", &development.bun.version);
        self.set_optional("SWAWKIT_PROJ_BUN_SHA256", &development.bun.sha256);
        self.set("SWAWKIT_PROJ_PWSH_MODE", &development.pwsh.mode);
        self.set("SWAWKIT_PROJ_PWSH_VERSION", &development.pwsh.version);
        self.set_optional("SWAWKIT_PROJ_PWSH_SHA256", &development.pwsh.sha256);
        self.set("SWAWKIT_PROJ_MSVC_MODE", &development.msvc.mode);
        self.set("SWAWKIT_PROJ_MSVC_CHANNEL", &development.msvc.channel);
        self.set("SWAWKIT_PROJ_RUST_MODE", &development.rust.mode);
        self.set("SWAWKIT_PROJ_RUST_TOOLCHAIN", &development.rust.toolchain);
        self.set("SWAWKIT_PROJ_RUST_PROFILE", &development.rust.profile);
        self.set("SWAWKIT_PROJ_RUST_HOST", &development.rust.host);
        self.set("SWAWKIT_PROJ_UV_MODE", &development.uv.mode);
        self.set("SWAWKIT_PROJ_UV_VERSION", &development.uv.version);
        self.set("SWAWKIT_PROJ_PYTHON_MODE", &development.python.mode);
        self.set("SWAWKIT_PROJ_PYTHON_VERSION", &development.python.version);
        self.set("SWAWKIT_PROJ_GO_MODE", &development.go.mode);
        self.set_optional("SWAWKIT_PROJ_GO_VERSION", &development.go.version);
        self.set("SWAWKIT_PROJ_GH_MODE", &development.gh.mode);
        self.set("SWAWKIT_PROJ_VSCODE_MODE", &development.vscode.mode);
        self.set("SWAWKIT_PROJ_CURSOR_MODE", &development.cursor.mode);

        self.set_optional("SWAWKIT_PROJ_GIT_ID_NAME", &profile.git.name);
        self.set_optional("SWAWKIT_PROJ_GIT_ID_EMAIL", &profile.git.email);
        self.set_optional("SWAWKIT_PROJ_GIT_ID_ACCESS", &profile.git.access);
        self.set_optional("SWAWKIT_PROJ_REPO_REMOTE", &profile.repository.remote);
    }

    fn set(&mut self, name: impl Into<OsString>, value: impl AsRef<OsStr>) {
        self.values
            .insert(name.into(), Some(value.as_ref().to_os_string()));
    }

    fn remove(&mut self, name: impl Into<OsString>) {
        self.values.insert(name.into(), None);
    }

    fn set_optional(&mut self, name: &'static str, value: &str) {
        if value.is_empty() {
            self.remove(name);
        } else {
            self.set(name, value);
        }
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
