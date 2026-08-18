use std::path::PathBuf;

use crate::catalog::{CatalogSnapshot, CommandAdapter, CommandSpace};

use super::{CommandError, CommandResult};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedCommand {
    pub address: String,
    pub space: CommandSpace,
    pub namespace: Option<String>,
    pub path: Vec<String>,
    pub directory: PathBuf,
    pub entry_path: PathBuf,
    pub adapter: CommandAdapter,
    pub handler: Option<String>,
    pub native_owner: Option<String>,
}

impl ResolvedCommand {
    pub(crate) fn from_catalog(snapshot: &CatalogSnapshot, address: &str) -> CommandResult<Self> {
        let mut matches = snapshot
            .commands
            .iter()
            .filter(|node| node.address == address);
        let Some(node) = matches.next() else {
            return Err(CommandError::new(format!(
                "command not found: {}",
                display_address(address)
            )));
        };
        if matches.next().is_some() {
            return Err(CommandError::new(format!(
                "ambiguous command address: {}",
                display_address(address)
            )));
        }
        if !node.runnable {
            let reason = node
                .diagnostic
                .as_deref()
                .unwrap_or("the command has no recognized executable entry");
            return Err(CommandError::new(format!(
                "command '{}' is not runnable: {reason}",
                display_address(address)
            )));
        }

        let entry_name = node.entry.as_deref().ok_or_else(|| {
            CommandError::new(format!(
                "Catalog invariant failed for '{}': runnable command has no entry",
                display_address(address)
            ))
        })?;
        let adapter = node
            .adapter
            .as_deref()
            .and_then(CommandAdapter::from_name)
            .ok_or_else(|| {
                CommandError::new(format!(
                    "Catalog invariant failed for '{}': unknown adapter",
                    display_address(address)
                ))
            })?;

        Ok(Self {
            address: address.to_owned(),
            space: node.space,
            namespace: node.namespace.clone(),
            path: node.path.clone(),
            directory: node.directory.clone(),
            entry_path: node.directory.join(entry_name),
            adapter,
            handler: node.handler.clone(),
            native_owner: node.native_owner.clone(),
        })
    }
}

fn display_address(address: &str) -> &str {
    if address.is_empty() {
        "<root>"
    } else {
        address
    }
}
