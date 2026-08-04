use std::error::Error;
use std::ffi::OsString;
use std::fmt;
use std::io::{self, Write};

use swawkit_proj::{
    catalog::{CatalogSnapshot, is_help_marker},
    context::EntryContext,
    help::{HelpRenderError, render_help},
};

pub fn run(context: &EntryContext, argv: &[OsString]) -> Result<(), CliError> {
    let target = help_target(argv)?.ok_or_else(|| {
        CliError::new(
            "this Rust CLI slice currently supports only '.help' and '<address> .help'; command execution still uses the PowerShell entry"
                .to_owned(),
        )
    })?;
    let snapshot = CatalogSnapshot::discover(context)
        .map_err(|error| CliError::new(format!("catalog discovery failed: {error}")))?;
    let output = match render_help(&snapshot, &target) {
        Ok(output) => output,
        Err(HelpRenderError::Unavailable(address)) if !address.is_empty() => {
            return Err(CliError::new(format!(
                "Proj help is not enabled for '{address}'; command-owned help execution has not migrated, so the command was not run"
            )));
        }
        Err(error) => return Err(CliError::new(error.to_string())),
    };
    write_output(&output)
        .map_err(|error| CliError::new(format!("cannot write CLI output: {error}")))
}

fn help_target(argv: &[OsString]) -> Result<Option<String>, CliError> {
    match argv {
        [marker] if marker.to_str().is_some_and(is_help_marker) => Ok(Some(String::new())),
        [target, marker] if marker.to_str().is_some_and(is_help_marker) => {
            let target = target.to_str().ok_or_else(|| {
                CliError::new("help target address is not valid Unicode".to_owned())
            })?;
            Ok(Some(target.to_owned()))
        }
        _ => Ok(None),
    }
}

fn write_output(output: &str) -> io::Result<()> {
    let stdout = io::stdout();
    let mut handle = stdout.lock();
    handle.write_all(output.as_bytes())?;
    handle.write_all(b"\n")?;
    handle.flush()
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CliError {
    message: String,
}

impl CliError {
    fn new(message: String) -> Self {
        Self { message }
    }
}

impl fmt::Display for CliError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl Error for CliError {}

#[cfg(test)]
mod tests {
    use super::*;

    fn argv(values: &[&str]) -> Vec<OsString> {
        values.iter().map(OsString::from).collect()
    }

    #[test]
    fn recognizes_every_root_help_marker_exactly() {
        for marker in [".help", ".h", "-h", "--help"] {
            assert_eq!(help_target(&argv(&[marker])).unwrap(), Some(String::new()));
        }
        assert_eq!(help_target(&argv(&["--HELP"])).unwrap(), None);
    }

    #[test]
    fn recognizes_only_an_exact_target_help_shape() {
        assert_eq!(
            help_target(&argv(&[".dev", "--help"])).unwrap(),
            Some(".dev".to_owned())
        );
        assert_eq!(
            help_target(&argv(&[".dev", "--help", "extra"])).unwrap(),
            None
        );
        assert_eq!(help_target(&argv(&[".dev", "--", "--help"])).unwrap(), None);
        assert_eq!(
            help_target(&argv(&["", ".help"])).unwrap(),
            Some(String::new())
        );
    }

    #[test]
    fn non_help_invocations_are_left_for_later_command_execution() {
        assert_eq!(help_target(&[]).unwrap(), None);
        assert_eq!(help_target(&argv(&[".dev"])).unwrap(), None);
        assert_eq!(help_target(&argv(&[".dev", "value"])).unwrap(), None);
    }
}
