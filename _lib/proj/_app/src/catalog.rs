use crate::context::AppContext;
use serde::Serialize;
use std::collections::VecDeque;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

mod address;
mod filesystem;

use address::{child_address, parent_address};
use filesystem::{
    absolute_path, assert_command_root, child_directories, directory_files,
    named_directories, FileCandidate,
};

pub const CATALOG_PROTOCOL: &str = "swawkit.command-catalog/v1";

const ENTRY_PROTOCOL: [(&str, &str); 5] = [
    ("run.exe", "exe"),
    ("run.ts", "bun"),
    ("run.py", "python"),
    ("run.ps1", "powershell"),
    ("run.cmd", "cmd"),
];

const HELP_ALIASES: [(&str, &str); 3] = [
    (".h", ".help"),
    ("-h", ".help"),
    ("--help", ".help"),
];

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogSnapshot {
    pub protocol: &'static str,
    pub entry_name: String,
    pub commands: Vec<CommandNode>,
}

impl CatalogSnapshot {
    pub fn discover(context: &AppContext) -> io::Result<Self> {
        Self::discover_roots(
            &context.kernel_root(),
            &context.action_root,
            &context.entry_name,
        )
    }

    pub fn discover_roots(
        kernel_root: &Path,
        action_root: &Path,
        entry_name: &str,
    ) -> io::Result<Self> {
        assert_command_root(kernel_root)?;

        let mut pending = VecDeque::from([PendingDirectory {
            path: absolute_path(kernel_root)?,
            address: String::new(),
            source: CommandSource::Kernel,
            is_root: true,
        }]);

        if action_root.is_dir() {
            assert_command_root(action_root)?;
            pending.push_back(PendingDirectory {
                path: absolute_path(action_root)?,
                address: String::new(),
                source: CommandSource::Action,
                is_root: true,
            });
        }

        let mut commands = Vec::new();
        while let Some(current) = pending.pop_front() {
            if current.source == CommandSource::Kernel || !current.is_root {
                commands.push(scan_node(&current, entry_name));
            }

            for child in child_directories(&current.path)? {
                let Some(address) = child_address(&current, &child.name) else {
                    continue;
                };
                pending.push_back(PendingDirectory {
                    path: child.path,
                    address,
                    source: current.source,
                    is_root: false,
                });
            }
        }

        commands.sort_by(|left, right| {
            left.source
                .cmp(&right.source)
                .then_with(|| left.address.cmp(&right.address))
        });

        Ok(Self {
            protocol: CATALOG_PROTOCOL,
            entry_name: entry_name.to_owned(),
            commands,
        })
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandNode {
    pub address: String,
    pub source: CommandSource,
    pub parent: Option<String>,
    pub alias_of: Option<String>,
    pub runnable: bool,
    pub entry: Option<String>,
    pub adapter: Option<String>,
    pub help: Option<HelpDocument>,
    pub diagnostic: Option<String>,
    #[serde(skip)]
    pub directory: PathBuf,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum CommandSource {
    Kernel,
    Action,
}

#[derive(Debug, Clone, Serialize)]
pub struct HelpDocument {
    pub summary: String,
    pub text: String,
}

#[derive(Debug)]
struct PendingDirectory {
    path: PathBuf,
    address: String,
    source: CommandSource,
    is_root: bool,
}

fn scan_node(pending: &PendingDirectory, entry_name: &str) -> CommandNode {
    let mut diagnostics = Vec::new();
    let entry = match resolve_entry(&pending.path) {
        Ok(entry) => entry,
        Err(error) => {
            diagnostics.push(error.to_string());
            None
        }
    };
    let help = match read_local_help(&pending.path, entry_name, &pending.address) {
        Ok(help) => help,
        Err(error) => {
            diagnostics.push(error.to_string());
            None
        }
    };

    CommandNode {
        address: pending.address.clone(),
        source: pending.source,
        parent: parent_address(pending.source, &pending.address),
        alias_of: command_alias(pending.source, &pending.address).map(str::to_owned),
        runnable: entry.is_some(),
        entry: entry.as_ref().map(|entry| entry.name.to_owned()),
        adapter: entry.map(|entry| entry.adapter.to_owned()),
        help,
        diagnostic: (!diagnostics.is_empty()).then(|| diagnostics.join("; ")),
        directory: pending.path.clone(),
    }
}

fn command_alias(source: CommandSource, address: &str) -> Option<&'static str> {
    if source != CommandSource::Kernel {
        return None;
    }
    HELP_ALIASES
        .iter()
        .find_map(|(alias, target)| (*alias == address).then_some(*target))
}

#[derive(Debug)]
struct ResolvedEntry {
    name: &'static str,
    adapter: &'static str,
}

fn resolve_entry(directory: &Path) -> io::Result<Option<ResolvedEntry>> {
    let files = directory_files(directory)?;
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
        });
    }

    if existing.len() > 1 {
        return invalid_data(format!(
            "command directory '{}' contains multiple run entries: {}. \
             Exactly one run.* is allowed",
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

fn read_local_help(
    command_directory: &Path,
    entry_name: &str,
    address: &str,
) -> io::Result<Option<HelpDocument>> {
    let directories = named_directories(command_directory, "_help")?;
    if directories.len() > 1 {
        return invalid_data(format!(
            "help directory name collision below '{}'",
            command_directory.display()
        ));
    }
    let Some(help_directory) = directories.first() else {
        return Ok(None);
    };
    if help_directory.name != "_help" {
        return invalid_data(format!(
            "non-canonical help directory '{}'; expected '_help'",
            help_directory.name
        ));
    }
    if help_directory.reparse_point {
        return invalid_data(format!(
            "help directory cannot be a reparse point: {}",
            help_directory.path.display()
        ));
    }

    let files: Vec<FileCandidate> = directory_files(&help_directory.path)?
        .into_iter()
        .filter(|file| file.name.eq_ignore_ascii_case("zh-CN.txt"))
        .collect();
    if files.len() > 1 {
        return invalid_data(format!(
            "help file name collision below '{}'",
            help_directory.path.display()
        ));
    }
    let Some(help_file) = files.first() else {
        return Ok(None);
    };
    if help_file.name != "zh-CN.txt" {
        return invalid_data(format!(
            "non-canonical help file '{}'; expected 'zh-CN.txt'",
            help_file.name
        ));
    }
    if help_file.reparse_point {
        return invalid_data(format!(
            "help file cannot be a reparse point: {}",
            help_file.path.display()
        ));
    }

    let text = fs::read_to_string(&help_file.path)?;
    let summary = text
        .lines()
        .find(|line| !line.trim().is_empty())
        .map(str::trim)
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("help file is empty: {}", help_file.path.display()),
            )
        })?;
    let invocation = if address.is_empty() {
        entry_name.to_owned()
    } else {
        format!("{entry_name} {address}")
    };

    Ok(Some(HelpDocument {
        summary: expand_help(summary, entry_name, address, &invocation),
        text: expand_help(&text, entry_name, address, &invocation),
    }))
}

fn expand_help(text: &str, entry_name: &str, address: &str, invocation: &str) -> String {
    text.replace("{{COMMAND}}", entry_name)
        .replace("{{ADDRESS}}", address)
        .replace("{{INVOCATION}}", invocation)
}

fn invalid_data<T>(message: String) -> io::Result<T> {
    Err(io::Error::new(io::ErrorKind::InvalidData, message))
}

#[cfg(test)]
mod tests;
