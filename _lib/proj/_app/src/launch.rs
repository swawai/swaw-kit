use std::env;
use std::error::Error;
use std::ffi::{OsStr, OsString};
use std::fmt;
use std::path::PathBuf;

pub const ENTRY_FILE_ENV: &str = "SWAWKIT_PROJ_ENTRY_FILE";
pub const LAUNCH_MODE_ENV: &str = "SWAWKIT_PROJ_LAUNCH_MODE";

const ARGV_PROTOCOL_ENV: &str = "SWAWKIT_PROJ_ARGV_PROTOCOL";
const ARGV_COUNT_ENV: &str = "SWAWKIT_PROJ_ARGV_COUNT";
const ARGV_ITEM_PREFIX: &str = "SWAWKIT_PROJ_ARGV_";

/// Selects the composition root without consuming a user argument.
///
/// A native launcher passes user arguments directly and selects `cli` or
/// `internal-host` without consuming a user argument.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum LaunchMode {
    #[default]
    Cli,
    InternalHost,
}

impl LaunchMode {
    pub const fn as_env_value(self) -> &'static str {
        match self {
            Self::Cli => "cli",
            Self::InternalHost => "internal-host",
        }
    }
}

/// Raw, lossless facts captured at the process boundary.
///
/// This type deliberately does not resolve the entry identity or inspect the
/// filesystem. Those rules belong to `EntryContext`, after launch transport
/// details have been removed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LaunchRequest {
    pub mode: LaunchMode,
    pub entry_file: PathBuf,
    pub invocation_dir: PathBuf,
    pub argv: Vec<OsString>,
}

impl LaunchRequest {
    pub fn from_process() -> Result<Self, LaunchError> {
        let invocation_dir = env::current_dir().map_err(|error| {
            LaunchError::new(format!("cannot read the invocation directory: {error}"))
        })?;

        Self::from_sources(env::args_os().skip(1), invocation_dir, |name| {
            env::var_os(name)
        })
    }

    fn from_sources(
        direct_argv: impl IntoIterator<Item = OsString>,
        invocation_dir: PathBuf,
        mut lookup: impl FnMut(&str) -> Option<OsString>,
    ) -> Result<Self, LaunchError> {
        let mode = read_mode(&mut lookup)?;
        let entry_file = read_entry_file(&mut lookup)?;
        let argv = read_argv(direct_argv, &mut lookup)?;

        Ok(Self {
            mode,
            entry_file,
            invocation_dir,
            argv,
        })
    }
}

fn read_mode(lookup: &mut impl FnMut(&str) -> Option<OsString>) -> Result<LaunchMode, LaunchError> {
    let Some(value) = lookup(LAUNCH_MODE_ENV) else {
        return Ok(LaunchMode::Cli);
    };

    if value == OsStr::new(LaunchMode::Cli.as_env_value()) {
        return Ok(LaunchMode::Cli);
    }
    if value == OsStr::new(LaunchMode::InternalHost.as_env_value()) {
        return Ok(LaunchMode::InternalHost);
    }

    Err(LaunchError::new(format!(
        "unsupported {LAUNCH_MODE_ENV} value '{}'; expected 'cli' or 'internal-host'",
        value.to_string_lossy()
    )))
}

fn read_entry_file(
    lookup: &mut impl FnMut(&str) -> Option<OsString>,
) -> Result<PathBuf, LaunchError> {
    let value = lookup(ENTRY_FILE_ENV).ok_or_else(|| {
        LaunchError::new(format!(
            "required launch declaration is missing: {ENTRY_FILE_ENV}"
        ))
    })?;
    if value.is_empty() {
        return Err(LaunchError::new(format!(
            "required launch declaration is missing: {ENTRY_FILE_ENV}"
        )));
    }

    let path = PathBuf::from(value);
    if !path.is_absolute() {
        return Err(LaunchError::new(format!(
            "launch path declaration {ENTRY_FILE_ENV} must be absolute: {}",
            path.display()
        )));
    }
    Ok(path)
}

fn read_argv(
    direct_argv: impl IntoIterator<Item = OsString>,
    lookup: &mut impl FnMut(&str) -> Option<OsString>,
) -> Result<Vec<OsString>, LaunchError> {
    let Some(protocol) = lookup(ARGV_PROTOCOL_ENV) else {
        return Ok(direct_argv.into_iter().collect());
    };
    if protocol != OsStr::new("1") {
        return Err(LaunchError::new(format!(
            "unsupported {ARGV_PROTOCOL_ENV} value '{}'",
            protocol.to_string_lossy()
        )));
    }

    let count_value = lookup(ARGV_COUNT_ENV).ok_or_else(|| {
        LaunchError::new(format!(
            "invalid project argv relay count: {ARGV_COUNT_ENV} is missing"
        ))
    })?;
    let count = parse_argv_count(&count_value)?;
    let mut argv = Vec::with_capacity(count);
    for index in 1..=count {
        let name = format!("{ARGV_ITEM_PREFIX}{index}");
        // CMD represents an explicit empty argument by removing the variable.
        // The declared count therefore makes a missing slot an empty OsString.
        argv.push(lookup(&name).unwrap_or_default());
    }
    Ok(argv)
}

fn parse_argv_count(value: &OsStr) -> Result<usize, LaunchError> {
    let text = value.to_str().ok_or_else(|| invalid_argv_count(value))?;
    if text.is_empty() || !text.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(invalid_argv_count(value));
    }

    // Match the legacy PowerShell protocol, whose count is a non-negative Int32.
    text.parse::<i32>()
        .ok()
        .filter(|count| *count >= 0)
        .map(|count| count as usize)
        .ok_or_else(|| invalid_argv_count(value))
}

fn invalid_argv_count(value: &OsStr) -> LaunchError {
    LaunchError::new(format!(
        "invalid project argv relay count '{}'",
        value.to_string_lossy()
    ))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LaunchError {
    message: String,
}

impl LaunchError {
    fn new(message: String) -> Self {
        Self { message }
    }
}

impl fmt::Display for LaunchError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl Error for LaunchError {}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn request(
        direct_argv: &[&str],
        declarations: &[(&str, &str)],
    ) -> Result<LaunchRequest, LaunchError> {
        let declarations: HashMap<String, OsString> = declarations
            .iter()
            .map(|(name, value)| ((*name).to_owned(), OsString::from(value)))
            .collect();

        LaunchRequest::from_sources(
            direct_argv.iter().map(OsString::from),
            PathBuf::from(r"C:\work\project"),
            |name| declarations.get(name).cloned(),
        )
    }

    #[test]
    fn native_launcher_arguments_are_preserved_without_a_relay_envelope() {
        let result = request(
            &[".demo", "", "a&b|c", "带 空格"],
            &[(ENTRY_FILE_ENV, r"C:\swaw\Favorites\项目.exe")],
        )
        .unwrap();

        assert_eq!(result.mode, LaunchMode::Cli);
        assert_eq!(
            result.argv,
            [".demo", "", "a&b|c", "带 空格"].map(OsString::from)
        );
        assert_eq!(result.invocation_dir, PathBuf::from(r"C:\work\project"));
    }

    #[test]
    fn legacy_envelope_takes_precedence_and_preserves_empty_arguments() {
        let result = request(
            &["this direct argument must be ignored"],
            &[
                (ENTRY_FILE_ENV, r"C:\swaw\swawkit.cmd"),
                (ARGV_PROTOCOL_ENV, "1"),
                (ARGV_COUNT_ENV, "4"),
                ("SWAWKIT_PROJ_ARGV_1", ".demo"),
                // Slot 2 is absent because CMD cannot retain an empty value.
                ("SWAWKIT_PROJ_ARGV_3", "%PATH%"),
                ("SWAWKIT_PROJ_ARGV_4", "你好 & goodbye"),
            ],
        )
        .unwrap();

        assert_eq!(
            result.argv,
            [".demo", "", "%PATH%", "你好 & goodbye"].map(OsString::from)
        );
    }

    #[test]
    fn zero_count_envelope_yields_no_arguments() {
        let result = request(
            &["ignored"],
            &[
                (ENTRY_FILE_ENV, r"C:\swaw\swawkit.cmd"),
                (ARGV_PROTOCOL_ENV, "1"),
                (ARGV_COUNT_ENV, "0"),
            ],
        )
        .unwrap();

        assert!(result.argv.is_empty());
    }

    #[test]
    fn internal_host_mode_is_transport_metadata_not_a_user_argument() {
        let result = request(
            &["--swawkit-internal-host", ".demo"],
            &[
                (ENTRY_FILE_ENV, r"C:\swaw\Favorites\project.exe"),
                (LAUNCH_MODE_ENV, "internal-host"),
            ],
        )
        .unwrap();

        assert_eq!(result.mode, LaunchMode::InternalHost);
        assert_eq!(
            result.argv,
            ["--swawkit-internal-host", ".demo"].map(OsString::from)
        );
    }

    #[test]
    fn explicit_cli_mode_is_accepted() {
        let result = request(
            &[],
            &[
                (ENTRY_FILE_ENV, r"C:\swaw\Favorites\project.exe"),
                (LAUNCH_MODE_ENV, "cli"),
            ],
        )
        .unwrap();

        assert_eq!(result.mode, LaunchMode::Cli);
    }

    #[test]
    fn unknown_launch_mode_fails_closed() {
        let error = request(
            &[],
            &[
                (ENTRY_FILE_ENV, r"C:\swaw\Favorites\project.exe"),
                (LAUNCH_MODE_ENV, "daemon"),
            ],
        )
        .unwrap_err();

        assert!(
            error
                .to_string()
                .contains("expected 'cli' or 'internal-host'")
        );
    }

    #[test]
    fn entry_file_is_required_and_absolute() {
        let missing = request(&[], &[]).unwrap_err();
        assert!(missing.to_string().contains(ENTRY_FILE_ENV));

        let relative = request(&[], &[(ENTRY_FILE_ENV, "project.exe")]).unwrap_err();
        assert!(relative.to_string().contains("must be absolute"));
    }

    #[test]
    fn invalid_legacy_protocol_and_count_fail_closed() {
        let protocol = request(
            &[],
            &[
                (ENTRY_FILE_ENV, r"C:\swaw\swawkit.cmd"),
                (ARGV_PROTOCOL_ENV, "2"),
                (ARGV_COUNT_ENV, "0"),
            ],
        )
        .unwrap_err();
        assert!(protocol.to_string().contains(ARGV_PROTOCOL_ENV));

        for invalid_count in ["", "-1", "+1", " 1", "2147483648"] {
            let error = request(
                &[],
                &[
                    (ENTRY_FILE_ENV, r"C:\swaw\swawkit.cmd"),
                    (ARGV_PROTOCOL_ENV, "1"),
                    (ARGV_COUNT_ENV, invalid_count),
                ],
            )
            .unwrap_err();
            assert!(
                error
                    .to_string()
                    .contains("invalid project argv relay count"),
                "unexpected error for {invalid_count:?}: {error}"
            );
        }
    }
}
