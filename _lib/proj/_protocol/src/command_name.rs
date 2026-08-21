pub fn valid_command_segment(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value.bytes().enumerate().all(|(index, byte)| {
            byte.is_ascii_lowercase() || (index > 0 && (byte.is_ascii_digit() || byte == b'-'))
        })
        && !matches!(
            value,
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

pub fn valid_module_namespace(value: &str) -> bool {
    valid_command_segment(value) && !matches!(value, "system" | "module")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn portable_names_exclude_devices_and_reserved_namespaces() {
        for valid in ["context", "build-2", "project"] {
            assert!(valid_command_segment(valid), "{valid}");
        }
        for invalid in ["", "Context", "-context", "con", "lpt1"] {
            assert!(!valid_command_segment(invalid), "{invalid}");
        }
        assert!(!valid_module_namespace("system"));
        assert!(!valid_module_namespace("module"));
        assert!(valid_module_namespace("swaw"));
    }
}
