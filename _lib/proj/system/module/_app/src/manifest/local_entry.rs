use std::fs;
use std::path::{Path, PathBuf};

use crate::filesystem::is_reparse;

const ENTRY_PROTOCOL: [&str; 5] = ["run.exe", "run.ts", "run.py", "run.ps1", "run.cmd"];
const OBSOLETE_ENTRIES: [&str; 4] = [
    "run.core.json",
    "run.toolchain.json",
    "run.native",
    "run.delegate",
];

struct FileCandidate {
    name: String,
    path: PathBuf,
    reparse_point: bool,
}

pub(super) fn resolve(directory: &Path) -> Result<Option<&'static str>, String> {
    let files = directory_files(directory)?;
    if let Some(file) = files.iter().find(|file| {
        OBSOLETE_ENTRIES
            .iter()
            .any(|name| file.name.eq_ignore_ascii_case(name))
    }) {
        return Err(format!(
            "obsolete command entry '{}'; declare execution in swawkit.module.json",
            file.path.display()
        ));
    }

    let mut existing = Vec::new();
    for canonical_name in ENTRY_PROTOCOL {
        let matches = files
            .iter()
            .filter(|file| file.name.eq_ignore_ascii_case(canonical_name))
            .collect::<Vec<_>>();
        if matches.len() > 1 {
            return Err(format!(
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
            return Err(format!(
                "non-canonical entry name '{}' in '{}'; expected '{canonical_name}'",
                file.name,
                directory.display()
            ));
        }
        if file.reparse_point {
            return Err(format!(
                "command entry cannot be a reparse point: {}",
                file.path.display()
            ));
        }
        existing.push(canonical_name);
    }

    if existing.len() > 1 {
        return Err(format!(
            "command directory '{}' contains multiple run entries: {}. Exactly one run.* is allowed",
            directory.display(),
            existing.join(", ")
        ));
    }
    Ok(existing.pop())
}

fn directory_files(directory: &Path) -> Result<Vec<FileCandidate>, String> {
    let mut files = Vec::new();
    for entry in fs::read_dir(directory)
        .map_err(|error| format!("cannot enumerate '{}': {error}", directory.display()))?
    {
        let entry = entry
            .map_err(|error| format!("cannot enumerate '{}': {error}", directory.display()))?;
        let path = entry.path();
        let metadata = fs::symlink_metadata(&path)
            .map_err(|error| format!("cannot inspect entry '{}': {error}", path.display()))?;
        let reparse_point = is_reparse(&metadata);
        if !metadata.is_file() && !reparse_point {
            continue;
        }
        let Ok(name) = entry.file_name().into_string() else {
            continue;
        };
        files.push(FileCandidate {
            name,
            path,
            reparse_point,
        });
    }
    Ok(files)
}
