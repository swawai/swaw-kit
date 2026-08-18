use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::{ProtocolError, ProtocolResult, valid_command_segment, valid_module_namespace};

pub const MAX_COMMAND_ADDRESS_BYTES: usize = 256;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum CommandSpace {
    System,
    Module,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct CommandIdentity {
    space: CommandSpace,
    namespace: Option<String>,
    path: Vec<String>,
}

impl CommandIdentity {
    pub fn new(
        space: CommandSpace,
        namespace: Option<&str>,
        path: Vec<String>,
    ) -> ProtocolResult<Self> {
        if path.is_empty() || !path.iter().all(|segment| valid_command_segment(segment)) {
            return Err(ProtocolError::new(
                "invalid canonical command identity path",
            ));
        }
        let namespace = match (space, namespace) {
            (CommandSpace::System, None) => None,
            (CommandSpace::Module, Some(value)) if valid_module_namespace(value) => {
                Some(value.to_owned())
            }
            _ => {
                return Err(ProtocolError::new(
                    "command identity space and namespace are incompatible",
                ));
            }
        };
        let identity = Self {
            space,
            namespace,
            path,
        };
        if identity.address().len() > MAX_COMMAND_ADDRESS_BYTES {
            return Err(ProtocolError::new(
                "canonical command identity exceeds its address limit",
            ));
        }
        Ok(identity)
    }

    pub fn parse(address: &str) -> ProtocolResult<Self> {
        if address.len() > MAX_COMMAND_ADDRESS_BYTES {
            return Err(invalid_address(address));
        }
        if let Some(path) = address.strip_prefix('.') {
            let path = parse_path(address, path)?;
            return Self::new(CommandSpace::System, None, path);
        }

        let Some((namespace, path)) = address.split_once('/') else {
            return Err(invalid_address(address));
        };
        Self::new(
            CommandSpace::Module,
            Some(namespace),
            parse_path(address, path)?,
        )
        .map_err(|_| invalid_address(address))
    }

    pub fn space(&self) -> CommandSpace {
        self.space
    }

    pub fn namespace(&self) -> Option<&str> {
        self.namespace.as_deref()
    }

    pub fn path(&self) -> &[String] {
        &self.path
    }

    pub fn address(&self) -> String {
        match self.space {
            CommandSpace::System => format!(".{}", self.path.join("/")),
            CommandSpace::Module => format!(
                "{}/{}",
                self.namespace
                    .as_deref()
                    .expect("Module command identity must have a namespace"),
                self.path.join("/")
            ),
        }
    }

    pub fn is_true_ancestor_of(&self, command: &Self) -> bool {
        self.space == command.space
            && self.namespace == command.namespace
            && self.path.len() < command.path.len()
            && command.path.starts_with(&self.path)
    }
}

pub fn command_data_root(data_root: &Path, identity: &CommandIdentity) -> PathBuf {
    let mut root = data_root.join("modules");
    match identity.space {
        CommandSpace::System => root.push("system"),
        CommandSpace::Module => root.push(
            identity
                .namespace
                .as_deref()
                .expect("Module command identity must have a namespace"),
        ),
    }
    for segment in &identity.path {
        root.push(segment);
    }
    root
}

pub fn native_command_root(data_root: &Path, identity: &CommandIdentity) -> PathBuf {
    command_data_root(data_root, identity).join("_native")
}

fn parse_path(address: &str, path: &str) -> ProtocolResult<Vec<String>> {
    if path.is_empty() || !path.split('/').all(valid_command_segment) {
        return Err(invalid_address(address));
    }
    Ok(path.split('/').map(str::to_owned).collect())
}

fn invalid_address(value: &str) -> ProtocolError {
    ProtocolError::new(format!("invalid canonical command address '{value}'"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_system_and_module_command_identities() {
        let system = CommandIdentity::parse(".context/add").unwrap();
        assert_eq!(system.space(), CommandSpace::System);
        assert_eq!(system.namespace(), None);
        assert_eq!(system.path(), ["context", "add"]);
        assert_eq!(system.address(), ".context/add");

        let module = CommandIdentity::parse("swaw/context/add").unwrap();
        assert_eq!(module.space(), CommandSpace::Module);
        assert_eq!(module.namespace(), Some("swaw"));
        assert_eq!(module.path(), ["context", "add"]);
        assert_eq!(module.address(), "swaw/context/add");
    }

    #[test]
    fn rejects_roots_and_noncanonical_addresses() {
        for invalid in [
            "",
            ".",
            "system",
            "swaw",
            "system/context",
            ".Context",
            ".context//add",
            "swaw/-context",
        ] {
            assert!(CommandIdentity::parse(invalid).is_err(), "{invalid}");
        }
    }

    #[test]
    fn validated_constructor_enforces_space_namespace_and_path() {
        assert!(
            CommandIdentity::new(CommandSpace::System, None, vec!["context".to_owned()]).is_ok()
        );
        assert!(
            CommandIdentity::new(
                CommandSpace::Module,
                Some("swaw"),
                vec!["context".to_owned()]
            )
            .is_ok()
        );
        assert!(
            CommandIdentity::new(
                CommandSpace::System,
                Some("swaw"),
                vec!["context".to_owned()]
            )
            .is_err()
        );
        assert!(
            CommandIdentity::new(CommandSpace::Module, None, vec!["context".to_owned()]).is_err()
        );
        assert!(
            CommandIdentity::new(CommandSpace::System, None, vec!["a".to_owned(); 130]).is_err()
        );
    }

    #[test]
    fn ancestry_requires_one_space_and_module_namespace() {
        let system = CommandIdentity::parse(".context").unwrap();
        let system_child = CommandIdentity::parse(".context/add").unwrap();
        let module = CommandIdentity::parse("swaw/context").unwrap();
        let other_namespace = CommandIdentity::parse("project/context/add").unwrap();

        assert!(system.is_true_ancestor_of(&system_child));
        assert!(!system.is_true_ancestor_of(&module));
        assert!(!module.is_true_ancestor_of(&other_namespace));
        assert!(!system.is_true_ancestor_of(&system));
    }

    #[test]
    fn maps_both_spaces_into_the_canonical_data_root() {
        let data_root = Path::new("entry-data");
        assert_eq!(
            command_data_root(data_root, &CommandIdentity::parse(".context/add").unwrap()),
            data_root.join("modules/system/context/add")
        );
        assert_eq!(
            native_command_root(data_root, &CommandIdentity::parse("swaw/context").unwrap()),
            data_root.join("modules/swaw/context/_native")
        );
    }
}
