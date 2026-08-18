use super::{ChildCommand, PendingDirectory};

pub(super) fn child_address(
    parent: &PendingDirectory,
    directory_name: &str,
) -> Option<ChildCommand> {
    parent
        .id
        .child(directory_name)
        .map(|id| ChildCommand { id })
}
