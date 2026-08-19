use std::collections::BTreeMap;
use std::env;
use std::ffi::OsString;
use std::path::PathBuf;

use swawkit_proj_protocol::{serde_json, valid_module_namespace};

const TRANSPORT: &str = "command-v1";
const COMMAND_PROTOCOL: &str = "2";

pub(crate) struct Invocation {
    pub(crate) address: String,
    pub(crate) arguments: Vec<OsString>,
    pub(crate) context: CommandContext,
}

pub(crate) struct CommandContext {
    pub(crate) swawkit_home: PathBuf,
    pub(crate) data_root: PathBuf,
    pub(crate) system_root: PathBuf,
    pub(crate) module_roots: BTreeMap<String, PathBuf>,
}

impl Invocation {
    pub(crate) fn from_process() -> Result<Self, String> {
        Self::from_sources(env::args_os().skip(1), |name| env::var_os(name))
    }

    fn from_sources(
        arguments: impl IntoIterator<Item = OsString>,
        mut environment: impl FnMut(&str) -> Option<OsString>,
    ) -> Result<Self, String> {
        let mut arguments = arguments.into_iter();
        let transport = unicode(arguments.next(), "Module manager transport")?;
        if transport != TRANSPORT {
            return Err(format!(
                "unsupported Module manager transport '{transport}'; expected '{TRANSPORT}'"
            ));
        }
        let address = unicode(arguments.next(), "Module manager command address")?;
        if !matches!(address.as_str(), ".module/instantiate" | ".module/status") {
            return Err(format!(
                "unsupported Module manager command address '{address}'"
            ));
        }
        require_exact(
            &mut environment,
            "SWAWKIT_PROJ_CORE_COMMAND_PROTOCOL",
            COMMAND_PROTOCOL,
        )?;
        require_exact(
            &mut environment,
            "SWAWKIT_PROJ_CORE_COMMAND_ADDRESS",
            &address,
        )?;
        let data_root = absolute(
            required(&mut environment, "SWAWKIT_PROJ_DATA_ROOT")?,
            "DataRoot",
        )?;
        let swawkit_home = absolute(required(&mut environment, "SWAWKIT_HOME")?, "Swaw Kit Home")?;
        let system_root = absolute(
            required(&mut environment, "SWAWKIT_PROJ_SYSTEM_ROOT")?,
            "System command root",
        )?;
        let roots_text = required(&mut environment, "SWAWKIT_PROJ_MODULE_ROOTS")?;
        let module_roots: BTreeMap<String, PathBuf> = serde_json::from_str(&roots_text)
            .map_err(|error| format!("invalid Module root map: {error}"))?;
        for (namespace, root) in &module_roots {
            if !valid_module_namespace(namespace) {
                return Err(format!("invalid Module namespace '{namespace}'"));
            }
            if !root.is_absolute() {
                return Err(format!(
                    "Module root '{namespace}' must be absolute: {}",
                    root.display()
                ));
            }
        }
        required(&mut environment, "SWAWKIT_PROJ_ENTRY_COMMAND")?;
        Ok(Self {
            address,
            arguments: arguments.collect(),
            context: CommandContext {
                swawkit_home,
                data_root,
                system_root,
                module_roots,
            },
        })
    }
}

fn required(
    environment: &mut impl FnMut(&str) -> Option<OsString>,
    name: &str,
) -> Result<String, String> {
    unicode(environment(name), name).and_then(|value| {
        if value.is_empty() || value.trim() != value {
            Err(format!("required environment variable is invalid: {name}"))
        } else {
            Ok(value)
        }
    })
}

fn require_exact(
    environment: &mut impl FnMut(&str) -> Option<OsString>,
    name: &str,
    expected: &str,
) -> Result<(), String> {
    let actual = required(environment, name)?;
    if actual == expected {
        Ok(())
    } else {
        Err(format!(
            "unsupported {name} value '{actual}'; expected '{expected}'"
        ))
    }
}

fn unicode(value: Option<OsString>, label: &str) -> Result<String, String> {
    value
        .ok_or_else(|| format!("required {label} is missing"))?
        .into_string()
        .map_err(|_| format!("{label} must be valid Unicode"))
}

fn absolute(value: String, label: &str) -> Result<PathBuf, String> {
    let path = PathBuf::from(value);
    if path.is_absolute() {
        Ok(path)
    } else {
        Err(format!("{label} must be absolute: {}", path.display()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn environment(name: &str) -> Option<OsString> {
        match name {
            "SWAWKIT_PROJ_CORE_COMMAND_PROTOCOL" => Some("2".into()),
            "SWAWKIT_PROJ_CORE_COMMAND_ADDRESS" => Some(".module/status".into()),
            "SWAWKIT_PROJ_DATA_ROOT" => Some(r"C:\data".into()),
            "SWAWKIT_HOME" => Some(r"C:\home".into()),
            "SWAWKIT_PROJ_SYSTEM_ROOT" => Some(r"C:\system".into()),
            "SWAWKIT_PROJ_MODULE_ROOTS" => Some(r#"{"swaw":"C:\\modules"}"#.into()),
            "SWAWKIT_PROJ_ENTRY_COMMAND" => Some("fixture".into()),
            _ => None,
        }
    }

    #[test]
    fn transport_and_environment_must_describe_one_same_command() {
        let invocation = Invocation::from_sources(
            ["command-v1", ".module/status", "swaw/context"].map(OsString::from),
            environment,
        )
        .unwrap();
        assert_eq!(invocation.address, ".module/status");
        assert_eq!(invocation.arguments, [OsString::from("swaw/context")]);
        assert_eq!(invocation.context.swawkit_home, PathBuf::from(r"C:\home"));
        assert_eq!(invocation.context.system_root, PathBuf::from(r"C:\system"));
    }

    #[test]
    fn old_command_environment_protocol_is_rejected() {
        let error = Invocation::from_sources(
            ["command-v1", ".module/status", "swaw/context"].map(OsString::from),
            |name| {
                if name == "SWAWKIT_PROJ_CORE_COMMAND_PROTOCOL" {
                    Some("1".into())
                } else {
                    environment(name)
                }
            },
        )
        .err()
        .unwrap();
        assert!(error.contains("expected '2'"), "{error}");
    }

    #[test]
    fn system_native_commands_do_not_require_a_module_mount() {
        let invocation = Invocation::from_sources(
            ["command-v1", ".module/status", ".context"].map(OsString::from),
            |name| {
                if name == "SWAWKIT_PROJ_MODULE_ROOTS" {
                    Some("{}".into())
                } else {
                    environment(name)
                }
            },
        )
        .unwrap();
        assert!(invocation.context.module_roots.is_empty());
    }
}
