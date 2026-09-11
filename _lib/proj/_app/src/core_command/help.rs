use std::ffi::OsString;

use crate::catalog::{CatalogSnapshot, is_help_marker};
use crate::help::render_help;

use super::{CoreCommandError, CoreCommandOutcome};

pub fn execute(
    snapshot: &CatalogSnapshot,
    argv: &[OsString],
) -> Result<Option<CoreCommandOutcome>, CoreCommandError> {
    let Some(target) = target(argv)? else {
        return Ok(None);
    };
    let output = render_help(snapshot, &target)
        .map_err(|error| CoreCommandError::domain(error.to_string()))?;
    Ok(Some(CoreCommandOutcome::success(format!("{output}\n"))))
}

fn target(argv: &[OsString]) -> Result<Option<String>, CoreCommandError> {
    match argv {
        [marker] if marker.to_str().is_some_and(is_help_marker) => Ok(Some(String::new())),
        [marker, target] if marker.to_str().is_some_and(is_help_marker) => {
            let target = target.to_str().ok_or_else(|| {
                CoreCommandError::arguments("help target address is not valid Unicode")
            })?;
            Ok(Some(target.to_owned()))
        }
        _ => Ok(None),
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::*;
    use crate::catalog::{CATALOG_PROTOCOL, CommandNode, CommandSpace, HelpDocument};

    #[test]
    fn help_parser_leaves_command_owned_help_for_command_execution() {
        for arguments in [
            vec![".tool"],
            vec![".tool", "value"],
            vec![".tool", "--help"],
        ] {
            assert_eq!(target(&argv(&arguments)).unwrap(), None);
        }
        assert_eq!(
            target(&argv(&[".help", ".tool"])).unwrap(),
            Some(".tool".to_owned())
        );
    }

    #[test]
    fn help_returns_a_transport_neutral_outcome() {
        let snapshot = CatalogSnapshot {
            protocol: CATALOG_PROTOCOL,
            entry_name: "swawkit".to_owned(),
            language: "en",
            commands: vec![node("", "Root help")],
        };

        assert_eq!(
            execute(&snapshot, &argv(&[".help"])).unwrap(),
            Some(CoreCommandOutcome::success("Root help\n"))
        );
    }

    fn argv(values: &[&str]) -> Vec<OsString> {
        values.iter().map(OsString::from).collect()
    }

    fn node(address: &str, text: &str) -> CommandNode {
        CommandNode {
            address: address.to_owned(),
            space: CommandSpace::System,
            namespace: None,
            path: Vec::new(),
            parent: None,
            alias_of: None,
            runnable: false,
            entry: None,
            adapter: None,
            handler: None,
            product: None,
            requirements: Vec::new(),
            provisions: Vec::new(),
            delegate_owner: None,
            declares_native: false,
            declared_facets: Vec::new(),
            declared_resource_kinds: Vec::new(),
            help: Some(HelpDocument {
                summary: text.to_owned(),
                text: text.to_owned(),
            }),
            resource_kinds: Vec::new(),
            facets: Vec::new(),
            diagnostic: None,
            authored_resource: true,
            help_diagnostic: None,
            directory: PathBuf::new(),
            executor_directory: PathBuf::new(),
            native_owner: None,
        }
    }
}
