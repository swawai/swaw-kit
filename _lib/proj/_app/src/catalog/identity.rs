use serde::{Deserialize, Serialize};
use swawkit_proj_protocol::{valid_command_segment, valid_module_namespace};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum CommandSpace {
    System,
    Module,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct CommandId {
    pub(crate) space: CommandSpace,
    pub(crate) namespace: Option<String>,
    pub(crate) path: Vec<String>,
}

impl CommandId {
    pub(crate) fn system(path: Vec<String>) -> Self {
        Self {
            space: CommandSpace::System,
            namespace: None,
            path,
        }
    }

    pub(crate) fn module(namespace: impl Into<String>, path: Vec<String>) -> Self {
        Self {
            space: CommandSpace::Module,
            namespace: Some(namespace.into()),
            path,
        }
    }

    pub(crate) fn child(&self, segment: &str) -> Option<Self> {
        valid_segment(segment).then(|| {
            let mut path = self.path.clone();
            path.push(segment.to_owned());
            Self {
                space: self.space,
                namespace: self.namespace.clone(),
                path,
            }
        })
    }

    pub(crate) fn parent(&self) -> Option<Self> {
        if self.path.is_empty() {
            return None;
        }
        let mut path = self.path.clone();
        path.pop();
        Some(Self {
            space: self.space,
            namespace: self.namespace.clone(),
            path,
        })
    }

    pub(crate) fn address(&self) -> String {
        match self.space {
            CommandSpace::System => {
                if self.path.is_empty() {
                    String::new()
                } else {
                    format!(".{}", self.path.join("/"))
                }
            }
            CommandSpace::Module => {
                let namespace = self
                    .namespace
                    .as_deref()
                    .expect("Module CommandId must have a namespace");
                if self.path.is_empty() {
                    namespace.to_owned()
                } else {
                    format!("{namespace}/{}", self.path.join("/"))
                }
            }
        }
    }
}

pub(crate) fn valid_namespace(value: &str) -> bool {
    valid_module_namespace(value)
}

pub(crate) fn valid_segment(value: &str) -> bool {
    valid_command_segment(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_system_and_module_cli_addresses() {
        assert_eq!(
            CommandId::system(vec!["entry".to_owned(), "language".to_owned()]).address(),
            ".entry/language"
        );
        assert_eq!(
            CommandId::module("swaw", vec!["context".to_owned(), "add".to_owned()]).address(),
            "swaw/context/add"
        );
    }

    #[test]
    fn rejects_ambiguous_or_non_portable_names() {
        for invalid in ["", "System", "user_custom", "-local", "con"] {
            assert!(!valid_namespace(invalid), "{invalid}");
        }
        for valid in ["swaw", "project", "user-custom", "acme2"] {
            assert!(valid_namespace(valid), "{valid}");
        }
    }
}
