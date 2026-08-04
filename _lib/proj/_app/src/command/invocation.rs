use std::ffi::OsString;

use crate::catalog::{CatalogSnapshot, CommandSource, HELP_ADDRESS, is_help_marker};

use super::{CommandError, CommandResult, ResolvedCommand};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Invocation {
    pub command: ResolvedCommand,
    pub arguments: Vec<OsString>,
    pub help_target_address: Option<String>,
}

impl Invocation {
    pub(crate) fn resolve(
        snapshot: &CatalogSnapshot,
        argv: &[OsString],
    ) -> CommandResult<Self> {
        let address = argv
            .first()
            .map(|value| {
                value
                    .to_str()
                    .ok_or_else(|| CommandError::new("command address is not valid Unicode"))
            })
            .transpose()?
            .unwrap_or("");
        let raw_arguments = argv.get(1..).unwrap_or_default();

        let local_help = raw_arguments.len() == 1
            && raw_arguments[0].to_str().is_some_and(is_help_marker)
            && uses_local_help(snapshot, address)?;
        let (resolved_address, arguments, help_target_address) = if local_help {
            (HELP_ADDRESS, Vec::new(), Some(address.to_owned()))
        } else {
            (address, raw_arguments.to_vec(), None)
        };

        Ok(Self {
            command: ResolvedCommand::from_catalog(snapshot, resolved_address)?,
            arguments,
            help_target_address,
        })
    }
}

fn uses_local_help(snapshot: &CatalogSnapshot, address: &str) -> CommandResult<bool> {
    let mut matches = snapshot.commands.iter().filter(|node| {
        node.address == address
            && (!address.is_empty() || node.source == CommandSource::Kernel)
    });
    let Some(node) = matches.next() else {
        return Ok(false);
    };
    if matches.next().is_some() {
        return Err(CommandError::new(format!(
            "ambiguous help target address: {address}"
        )));
    }
    if let Some(diagnostic) = &node.help_diagnostic {
        return Err(CommandError::new(diagnostic.clone()));
    }
    Ok(node.help.is_some())
}
