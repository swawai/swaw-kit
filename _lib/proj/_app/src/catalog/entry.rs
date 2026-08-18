use std::io;
use std::path::{Path, PathBuf};

use super::{
    CommandSpace, MODULE_CONTRACT_FILE,
    filesystem::{FileCandidate, directory_files},
};
use crate::profile::EntryProfileRecord;

const ENTRY_PROTOCOL: [(&str, CommandAdapter); 5] = [
    ("run.exe", CommandAdapter::Exe),
    ("run.ts", CommandAdapter::Bun),
    ("run.py", CommandAdapter::Python),
    ("run.ps1", CommandAdapter::Pwsh),
    ("run.cmd", CommandAdapter::Cmd),
];
#[derive(Debug)]
pub(crate) struct ResolvedEntry {
    pub(crate) name: &'static str,
    pub(crate) adapter: CommandAdapter,
    pub(crate) path: PathBuf,
    pub(crate) handler: Option<String>,
}

impl ResolvedEntry {
    pub(super) fn declared(
        path: PathBuf,
        adapter: CommandAdapter,
        handler: Option<String>,
    ) -> Self {
        Self {
            name: MODULE_CONTRACT_FILE,
            adapter,
            path,
            handler,
        }
    }

    pub(super) fn has_valid_core_owner(&self, space: CommandSpace, address: &str) -> bool {
        space == CommandSpace::System
            && (matches!(
                (address, self.handler.as_deref()),
                (".entry", Some("entry.profile"))
                    | (".entry/apply", Some("entry.profile.apply"))
                    | (".entry/claim", Some("entry.claim"))
                    | (".runtime", Some("runtime.status"))
                    | (".runtime/cleanup", Some("runtime.cleanup"))
                    | (".runtime/host/exit", Some("host.exit"))
                    | (".runtime/host/restart", Some("host.restart"))
                    | (".check", Some("meta.check"))
                    | (".help", Some("meta.help"))
                    | (".runs", Some("meta.runs"))
            ) || (self.handler.as_deref() == Some("entry.profile.set")
                && EntryProfileRecord::is_profile_setting_address(address)))
    }

    pub(super) fn has_valid_toolchain_owner(&self, space: CommandSpace, address: &str) -> bool {
        space == CommandSpace::System
            && matches!(
                (address, self.handler.as_deref()),
                (".dev/setup", Some("dev.setup"))
                    | (".dev/status", Some("dev.status"))
                    | (".module/instantiate", Some("module.instantiate"))
            )
    }
}

pub(crate) fn resolve_entry(directory: &Path) -> io::Result<Option<ResolvedEntry>> {
    let files = directory_files(directory)?;
    if let Some(file) = files.iter().find(|file| {
        [
            "run.core.json",
            "run.toolchain.json",
            "run.native",
            "run.delegate",
        ]
        .iter()
        .any(|name| file.name.eq_ignore_ascii_case(name))
    }) {
        return invalid_data(format!(
            "obsolete command entry '{}'; declare execution in {MODULE_CONTRACT_FILE}",
            file.path.display(),
        ));
    }
    let mut existing = Vec::new();

    for (canonical_name, adapter) in ENTRY_PROTOCOL {
        let matches: Vec<&FileCandidate> = files
            .iter()
            .filter(|file| file.name.eq_ignore_ascii_case(canonical_name))
            .collect();
        if matches.len() > 1 {
            return invalid_data(format!(
                "entry name collision in '{}': {}",
                directory.display(),
                matches
                    .iter()
                    .map(|file| file.name.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            ));
        }
        let Some(file) = matches.first() else {
            continue;
        };
        if file.name != canonical_name {
            return invalid_data(format!(
                "non-canonical entry name '{}' in '{}'; expected '{canonical_name}'",
                file.name,
                directory.display()
            ));
        }
        if file.reparse_point {
            return invalid_data(format!(
                "command entry cannot be a reparse point: {}",
                file.path.display()
            ));
        }
        existing.push(ResolvedEntry {
            name: canonical_name,
            adapter,
            path: file.path.clone(),
            handler: None,
        });
    }

    if existing.len() > 1 {
        return invalid_data(format!(
            "command directory '{}' contains multiple run entries: {}. Exactly one run.* is allowed",
            directory.display(),
            existing
                .iter()
                .map(|entry| entry.name)
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }
    Ok(existing.pop())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CommandAdapter {
    Core,
    Toolchain,
    Native,
    Delegate,
    Exe,
    Bun,
    Python,
    Pwsh,
    Cmd,
}

impl CommandAdapter {
    pub(crate) fn from_name(value: &str) -> Option<Self> {
        match value {
            "core" => Some(Self::Core),
            "toolchain" => Some(Self::Toolchain),
            "native" => Some(Self::Native),
            "delegate" => Some(Self::Delegate),
            "exe" => Some(Self::Exe),
            "bun" => Some(Self::Bun),
            "python" => Some(Self::Python),
            "pwsh" => Some(Self::Pwsh),
            "cmd" => Some(Self::Cmd),
            _ => None,
        }
    }

    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Core => "core",
            Self::Toolchain => "toolchain",
            Self::Native => "native",
            Self::Delegate => "delegate",
            Self::Exe => "exe",
            Self::Bun => "bun",
            Self::Python => "python",
            Self::Pwsh => "pwsh",
            Self::Cmd => "cmd",
        }
    }

    pub(crate) fn is_bootstrap_safe(self) -> bool {
        matches!(self, Self::Exe | Self::Cmd)
    }
}

fn invalid_data<T>(message: String) -> io::Result<T> {
    Err(io::Error::new(io::ErrorKind::InvalidData, message))
}
