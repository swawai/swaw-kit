use std::collections::BTreeMap;
use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};
use std::process::Command;

use swawkit_proj_protocol::{
    CommandIdentity, command_data_root as identity_data_root, valid_module_namespace,
};

use crate::{
    binding::ProjectBinding,
    catalog::{CommandNode, CommandSpace},
    command_event::{COMMAND_EVENT_FRAME_PROTOCOL, COMMAND_EVENT_PROTOCOL_ENV},
    context::EntryContext,
    launch::{ENTRY_FILE_ENV, LAUNCH_MODE_ENV},
    profile::{EntryProfile, EntryProfileRecord},
};

use super::{CommandError, CommandResult, ResolvedCommand};

const CLEARED_INVOCATION_ENVIRONMENT: [&str; 4] = [
    ENTRY_FILE_ENV,
    LAUNCH_MODE_ENV,
    "SWAWKIT_PROJ_CORE_COMMAND_PHASE",
    "SWAWKIT_PROJ_CORE_COMMAND_GUARD_SCOPE",
];
const COMMAND_OWNER_ENVIRONMENT: [&str; 3] = [
    "SWAWKIT_PROJ_CORE_COMMAND_OWNER_ADDRESS",
    "SWAWKIT_PROJ_CORE_COMMAND_OWNER_DIR",
    "SWAWKIT_PROJ_CORE_COMMAND_OWNER_DATA_ROOT",
];
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandExecutionContext {
    pub swawkit_home: PathBuf,
    pub command_root: PathBuf,
    pub system_root: PathBuf,
    pub target_project_root: PathBuf,
    pub module_roots: BTreeMap<String, PathBuf>,
    pub data_root: PathBuf,
    pub entry_name: String,
    pub entry_file: PathBuf,
    pub invocation_directory: PathBuf,
    pub dev_executable: PathBuf,
    pub module_executable: PathBuf,
    pub command_runtime_id: String,
    pub profile: EntryProfileRecord,
    pub environment_input_revision: String,
    pub profile_revision: String,
    pub process_mode: CommandProcessMode,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum CommandProcessMode {
    #[default]
    InheritConsole,
    NoWindow,
}

impl CommandExecutionContext {
    pub fn new(
        entry: &EntryContext,
        profile: &EntryProfile,
        data_root: impl Into<PathBuf>,
        process_mode: CommandProcessMode,
    ) -> CommandResult<Self> {
        let binding = profile.binding();
        let mut module_roots = BTreeMap::new();
        for (namespace, root) in [
            ("swaw", entry.swaw_module_root()),
            ("project", binding.project_module_root()),
        ] {
            if root.is_dir() {
                module_roots.insert(namespace.to_owned(), root);
            }
        }
        module_roots.extend(
            binding
                .external_module_mounts()
                .iter()
                .map(|mount| (mount.namespace().to_owned(), mount.root().to_owned())),
        );
        let command_runtime_id = crate::runtime_release::command_runtime(entry)
            .map_err(|error| CommandError::new(format!("Command Runtime is invalid: {error}")))?
            .runtime_id;
        Ok(Self {
            swawkit_home: entry.swawkit_home.clone(),
            command_root: entry.command_root(),
            system_root: entry.system_root(),
            target_project_root: binding.target_project_root().to_path_buf(),
            module_roots,
            data_root: data_root.into(),
            entry_name: entry.entry_name.clone(),
            entry_file: entry.entry_file.clone(),
            invocation_directory: entry.invocation_directory.clone(),
            dev_executable: entry.sibling_product_executable("swawkit-proj-dev.exe"),
            module_executable: entry.sibling_product_executable("swawkit-proj-module.exe"),
            command_runtime_id,
            profile: profile.record().clone(),
            environment_input_revision: profile.environment_input_revision().to_owned(),
            profile_revision: profile.profile_revision().to_owned(),
            process_mode,
        })
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct ProcessEnvironment {
    values: BTreeMap<OsString, Option<OsString>>,
}

impl ProcessEnvironment {
    pub(crate) fn for_command(
        context: &CommandExecutionContext,
        protocol_command: &ResolvedCommand,
    ) -> CommandResult<Self> {
        let mut environment = Self::default();
        for name in CLEARED_INVOCATION_ENVIRONMENT {
            environment.remove(name);
        }
        for name in COMMAND_OWNER_ENVIRONMENT {
            environment.remove(name);
        }
        environment.set("SWAWKIT_PROJ_CORE_COMMAND_PROTOCOL", "2");
        environment.set(COMMAND_EVENT_PROTOCOL_ENV, COMMAND_EVENT_FRAME_PROTOCOL);
        environment.set(
            "SWAWKIT_PROJ_CORE_COMMAND_ADDRESS",
            &protocol_command.address,
        );
        environment.set(
            "SWAWKIT_PROJ_CORE_COMMAND_SPACE",
            match protocol_command.space {
                CommandSpace::System => "system",
                CommandSpace::Module => "module",
            },
        );
        environment.set_optional(
            "SWAWKIT_PROJ_CORE_COMMAND_NAMESPACE",
            protocol_command.namespace.as_deref().unwrap_or_default(),
        );
        environment.set("SWAWKIT_PROJ_CORE_COMMAND_DIR", &protocol_command.directory);
        environment.set(
            "SWAWKIT_PROJ_CORE_COMMAND_DATA_ROOT",
            command_data_root(context, protocol_command)?,
        );
        environment.set(
            "SWAWKIT_PROJ_CORE_COMMAND_INVOCATION_DIR",
            &context.invocation_directory,
        );
        environment.set("SWAWKIT_HOME", &context.swawkit_home);
        environment.set("SWAWKIT_PROJ_SYSTEM_ROOT", &context.system_root);
        environment.set(
            "SWAWKIT_PROJ_TARGET_PROJECT_ROOT",
            &context.target_project_root,
        );
        if let Some(project_root) = context.module_roots.get("project") {
            environment.set("SWAWKIT_PROJ_PROJECT_MODULE_ROOT", project_root);
        }
        let module_roots = serde_json::to_string(&context.module_roots).map_err(|error| {
            CommandError::new(format!("cannot serialize Module mount roots: {error}"))
        })?;
        environment.set("SWAWKIT_PROJ_MODULE_ROOTS", module_roots);
        environment.set("SWAWKIT_PROJ_DATA_ROOT", &context.data_root);
        environment.set("SWAWKIT_PROJ_ENTRY_COMMAND", &context.entry_name);
        environment.set(
            "SWAWKIT_PROJ_CORE_COMMAND_RUNTIME_ID",
            &context.command_runtime_id,
        );
        environment.set("SWAWKIT_PROJ_CORE_COMMAND_ENTRY_FILE", &context.entry_file);
        environment.set("SWAWKIT_PROJ_CORE_DEV_EXECUTABLE", &context.dev_executable);
        environment.set(
            "SWAWKIT_PROJ_CORE_COMMAND_ENVIRONMENT_INPUT_REVISION",
            &context.environment_input_revision,
        );
        environment.set(
            "SWAWKIT_PROJ_CORE_COMMAND_PROFILE_REVISION",
            &context.profile_revision,
        );
        environment.apply_profile(&context.profile);
        Ok(environment)
    }

    pub(crate) fn apply_native_owner(&mut self, address: &str, directory: &Path, data_root: &Path) {
        self.set("SWAWKIT_PROJ_CORE_COMMAND_OWNER_ADDRESS", address);
        self.set("SWAWKIT_PROJ_CORE_COMMAND_OWNER_DIR", directory);
        self.set("SWAWKIT_PROJ_CORE_COMMAND_OWNER_DATA_ROOT", data_root);
    }

    fn apply_profile(&mut self, profile: &EntryProfileRecord) {
        for (name, value, omit_when_empty) in profile.published_environment_variables() {
            if omit_when_empty {
                self.set_optional(name, &value);
            } else {
                self.set(name, value);
            }
        }
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

pub(crate) fn validate_dev_executable(path: &Path) -> CommandResult<()> {
    let metadata = std::fs::symlink_metadata(path).map_err(|error| {
        CommandError::new(format!(
            "the Runtime Component product 'dev' is unavailable at '{}': {error}",
            path.display()
        ))
    })?;
    if !metadata.is_file() {
        return Err(CommandError::new(format!(
            "the Runtime Component product 'dev' is not a regular file: '{}'",
            path.display()
        )));
    }
    crate::runtime_release::validate_product(path).map_err(|error| {
        CommandError::new(format!(
            "the Runtime Component product 'dev' is invalid: {error}"
        ))
    })
}

pub(crate) fn validate_module_executable(path: &Path) -> CommandResult<()> {
    let metadata = std::fs::symlink_metadata(path).map_err(|error| {
        CommandError::new(format!(
            "the Runtime Component product 'module' is unavailable at '{}': {error}",
            path.display()
        ))
    })?;
    if !metadata.is_file() {
        return Err(CommandError::new(format!(
            "the Runtime Component product 'module' is not a regular file: '{}'",
            path.display()
        )));
    }
    crate::runtime_release::validate_product(path).map_err(|error| {
        CommandError::new(format!(
            "the Runtime Component product 'module' is invalid: {error}"
        ))
    })
}

pub(crate) fn command_data_root(
    context: &CommandExecutionContext,
    command: &ResolvedCommand,
) -> CommandResult<PathBuf> {
    command_identity_data_root(
        &context.data_root,
        command.space,
        command.namespace.as_deref(),
        &command.path,
        &command.address,
    )
}

pub fn catalog_command_data_root(
    _context: &EntryContext,
    data_root: &Path,
    _binding: Option<&ProjectBinding>,
    command: &CommandNode,
) -> CommandResult<PathBuf> {
    command_identity_data_root(
        data_root,
        command.space,
        command.namespace.as_deref(),
        &command.path,
        &command.address,
    )
}

pub fn catalog_command_data_root_from_roots(
    data_root: &Path,
    command: &CommandNode,
) -> CommandResult<PathBuf> {
    command_identity_data_root(
        data_root,
        command.space,
        command.namespace.as_deref(),
        &command.path,
        &command.address,
    )
}

fn command_identity_data_root(
    data_root: &Path,
    space: CommandSpace,
    namespace: Option<&str>,
    path: &[String],
    address: &str,
) -> CommandResult<PathBuf> {
    // A mounted Module namespace root is a Catalog mount entry rather than a
    // protocol command identity, but it can still own a local run.* entry.
    if space == CommandSpace::Module && path.is_empty() {
        let namespace = namespace.filter(|value| valid_module_namespace(value)).ok_or_else(|| {
            CommandError::new(format!(
                "Catalog invariant failed for '{address}': Module mount has no canonical namespace"
            ))
        })?;
        return Ok(data_root.join("modules").join(namespace));
    }
    let identity = CommandIdentity::new(space, namespace, path.to_vec()).map_err(|error| {
        CommandError::new(format!("Catalog invariant failed for '{address}': {error}"))
    })?;
    Ok(identity_data_root(data_root, &identity))
}
