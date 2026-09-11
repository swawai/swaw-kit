use crate::error::{ContextError, ContextResult};
use crate::model::{
    CommandSpace, ContextCommand, is_windows_device_name, validate_command_address,
};

pub(crate) fn command_reference(address: &str) -> ContextResult<ContextCommand> {
    validate_command_address(address)?;
    if let Some(path) = address.strip_prefix('.') {
        validate_path(path, address)?;
        return Ok(ContextCommand {
            space: CommandSpace::System,
            namespace: None,
            address: address.to_owned(),
        });
    }

    let Some((namespace, path)) = address.split_once('/') else {
        return Err(invalid_address(address));
    };
    if !is_segment(namespace)
        || is_windows_device_name(namespace)
        || matches!(namespace, "system" | "module")
    {
        return Err(invalid_address(address));
    }
    validate_path(path, address)?;
    Ok(ContextCommand {
        space: CommandSpace::Module,
        namespace: Some(namespace.to_owned()),
        address: address.to_owned(),
    })
}

fn validate_path(value: &str, address: &str) -> ContextResult<()> {
    if value.is_empty()
        || value
            .split('/')
            .any(|segment| !is_segment(segment) || is_windows_device_name(segment))
    {
        Err(invalid_address(address))
    } else {
        Ok(())
    }
}

fn is_segment(segment: &str) -> bool {
    let mut bytes = segment.bytes();
    matches!(bytes.next(), Some(b'a'..=b'z'))
        && bytes.all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
}

fn invalid_address(address: &str) -> ContextError {
    ContextError::new(format!("invalid command address: {address}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_identity_is_lexical_and_does_not_require_a_live_provider() {
        assert_eq!(
            command_reference(".future/tool").unwrap().space,
            CommandSpace::System
        );
        let context = command_reference(".context").unwrap();
        assert_eq!(context.space, CommandSpace::System);
        assert_eq!(context.namespace, None);
        assert_eq!(
            command_reference("user-custom/build-app").unwrap().space,
            CommandSpace::Module
        );
        for invalid in [".Bad", "..entry", "build.app", "module/build", "swaw"] {
            assert!(command_reference(invalid).is_err(), "accepted {invalid}");
        }
    }
}
