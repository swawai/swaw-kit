use super::{CommandSource, PendingDirectory};

pub(super) fn parent_address(source: CommandSource, address: &str) -> Option<String> {
    if address.is_empty() {
        return None;
    }
    let separator = address.rfind('.');
    match (source, separator) {
        (CommandSource::Kernel, Some(0) | None) => Some(String::new()),
        (CommandSource::Kernel, Some(index)) => Some(address[..index].to_owned()),
        (CommandSource::Action, None) => Some(String::new()),
        (CommandSource::Action, Some(index)) => Some(address[..index].to_owned()),
    }
}

pub(super) fn child_address(
    parent: &PendingDirectory,
    directory_name: &str,
) -> Option<String> {
    if directory_name.starts_with('_') {
        return None;
    }
    match parent.source {
        CommandSource::Kernel if parent.is_root => {
            if let Some(segment) = directory_name.strip_prefix('.') {
                is_normal_segment(segment).then(|| directory_name.to_owned())
            } else {
                is_kernel_literal_segment(directory_name).then(|| directory_name.to_owned())
            }
        }
        CommandSource::Kernel => is_normal_segment(directory_name)
            .then(|| format!("{}.{}", parent.address, directory_name)),
        CommandSource::Action if parent.address.is_empty() => {
            is_normal_segment(directory_name).then(|| directory_name.to_owned())
        }
        CommandSource::Action => is_normal_segment(directory_name)
            .then(|| format!("{}.{}", parent.address, directory_name)),
    }
}

fn has_segment_syntax(segment: &str) -> bool {
    let mut characters = segment.bytes();
    matches!(characters.next(), Some(b'a'..=b'z'))
        && characters.all(|character| {
            character.is_ascii_lowercase() || character.is_ascii_digit() || character == b'-'
        })
}

fn is_normal_segment(segment: &str) -> bool {
    has_segment_syntax(segment)
        && !matches!(
            segment,
            "con"
                | "prn"
                | "aux"
                | "nul"
                | "com1"
                | "com2"
                | "com3"
                | "com4"
                | "com5"
                | "com6"
                | "com7"
                | "com8"
                | "com9"
                | "lpt1"
                | "lpt2"
                | "lpt3"
                | "lpt4"
                | "lpt5"
                | "lpt6"
                | "lpt7"
                | "lpt8"
                | "lpt9"
        )
}

fn is_kernel_literal_segment(segment: &str) -> bool {
    segment
        .strip_prefix("--")
        .or_else(|| segment.strip_prefix('-'))
        .is_some_and(has_segment_syntax)
}
