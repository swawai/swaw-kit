use std::collections::BTreeMap;

use swawkit_proj_protocol::CommandIdentity;

use super::{CommandNode, CommandSpace};

type NativeEntry = (
    CommandSpace,
    Option<String>,
    Vec<String>,
    Option<String>,
    bool,
);

pub(super) fn resolve_native_owners(commands: &mut [CommandNode]) {
    let entries = commands
        .iter()
        .map(|command| {
            (
                command.address.clone(),
                (
                    command.space,
                    command.namespace.clone(),
                    command.path.clone(),
                    command.adapter.clone(),
                    command.declares_native,
                ),
            )
        })
        .collect::<BTreeMap<_, _>>();

    for command in commands {
        match command.adapter.as_deref() {
            Some("native") if command.runnable => {
                command.native_owner = Some(command.address.clone());
            }
            Some("delegate") if command.runnable => {
                match delegated_native_owner(&entries, command) {
                    Ok(owner) => command.native_owner = Some(owner),
                    Err(diagnostic) => invalidate_delegate(command, diagnostic),
                }
            }
            _ => {}
        }
    }
}

fn invalidate_delegate(command: &mut CommandNode, diagnostic: String) {
    command.runnable = false;
    command.entry = None;
    command.adapter = None;
    command.handler = None;
    command.product = None;
    command.diagnostic = Some(match command.diagnostic.take() {
        Some(existing) => format!("{existing}; {diagnostic}"),
        None => diagnostic,
    });
}

fn delegated_native_owner(
    entries: &BTreeMap<String, NativeEntry>,
    command: &CommandNode,
) -> Result<String, String> {
    let Some(address) = command.delegate_owner.as_ref() else {
        return Err(format!(
            "delegated command '{}' has no execution owner declaration",
            command.address
        ));
    };
    let Some((owner_space, owner_namespace, owner_path, adapter, _)) = entries.get(address) else {
        return Err(format!(
            "delegated execution owner '{}' is missing from the Catalog",
            address
        ));
    };
    if *owner_space != command.space || owner_namespace != &command.namespace {
        return Err(format!(
            "delegated execution owner '{}' has an incompatible space and namespace",
            address
        ));
    }
    let owner_identity =
        CommandIdentity::new(*owner_space, owner_namespace.as_deref(), owner_path.clone())
            .map_err(|error| format!("invalid delegated execution owner identity: {error}"))?;
    let command_identity = CommandIdentity::new(
        command.space,
        command.namespace.as_deref(),
        command.path.clone(),
    )
    .map_err(|error| format!("invalid delegated command identity: {error}"))?;
    if !owner_identity.is_true_ancestor_of(&command_identity) {
        return Err(format!(
            "delegated execution owner '{}' must be an ancestor of '{}'",
            address, command.address
        ));
    }
    if let Some((nested_address, _)) = entries.iter().find(|(_, candidate)| {
        let (space, namespace, path, _, declares_native) = candidate;
        *declares_native
            && CommandIdentity::new(*space, namespace.as_deref(), path.clone()).is_ok_and(
                |nested| {
                    owner_identity.is_true_ancestor_of(&nested)
                        && nested.is_true_ancestor_of(&command_identity)
                },
            )
    }) {
        return Err(format!(
            "delegated command '{}' cannot cross nested native owner '{}' to reach '{}'",
            command.address, nested_address, address
        ));
    }
    if adapter.as_deref() != Some("native") {
        return Err(format!(
            "delegated execution owner '{}' must declare native execution",
            address
        ));
    }
    Ok(address.clone())
}
