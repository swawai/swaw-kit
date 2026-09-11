use std::ffi::OsString;
use std::fs;
use std::os::windows::fs::MetadataExt;
use std::path::{Path, PathBuf};

use windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT;

use super::{ensure_directory_chain, existing_directory_chain};

pub fn migrate_legacy_layout(data_root: &Path) -> Result<(), String> {
    let source = data_root.join("modules/kernel/.dev/setup");
    match fs::symlink_metadata(&source) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(format!("cannot inspect legacy development setup: {error}")),
        Ok(_) => {}
    }
    existing_directory_chain(
        data_root,
        &["modules", "kernel", ".dev", "setup"],
        "legacy development setup",
    )
    .map_err(|error| error.to_string())?;
    inspect_regular_tree(&source, "legacy development setup")?;

    let parent = ensure_directory_chain(
        data_root,
        &["modules", "system", "dev"],
        "development setup parent",
    )
    .map_err(|error| error.to_string())?;
    let destination = parent.join("setup");
    match fs::symlink_metadata(&destination) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            fs::rename(&source, &destination).map_err(|error| {
                format!(
                    "cannot migrate development setup '{}' to '{}': {error}",
                    source.display(),
                    destination.display()
                )
            })
        }
        Err(error) => Err(format!(
            "cannot inspect current development setup '{}': {error}",
            destination.display()
        )),
        Ok(_) => {
            existing_directory_chain(
                data_root,
                &["modules", "system", "dev", "setup"],
                "current development setup",
            )
            .map_err(|error| error.to_string())?;
            merge_into_journal_only_destination(&source, &destination)
        }
    }
}

fn merge_into_journal_only_destination(source: &Path, destination: &Path) -> Result<(), String> {
    let destination_members = entry_names(destination, "current development setup")?;
    if destination_members.as_slice() != [OsString::from("_runs")] {
        return Err(conflicting_state(source, destination));
    }

    let current_runs = destination.join("_runs");
    require_regular_directory(&current_runs, "current development setup journals")?;

    let source_members = entry_names(source, "legacy development setup")?;
    let legacy_runs = source.join("_runs");
    let legacy_has_runs = source_members.iter().any(|name| name == "_runs");
    let legacy_journals = if legacy_has_runs {
        require_regular_directory(&legacy_runs, "legacy development setup journals")?;
        entry_names(&legacy_runs, "legacy development setup journals")?
    } else {
        Vec::new()
    };

    // Enumerating names does not open the current journal members. In particular, the command
    // that triggered this migration owns one of these files with share_mode(0).
    let current_journals = entry_names(&current_runs, "current development setup journals")?;
    for name in &legacy_journals {
        if current_journals.iter().any(|current| current == name) {
            return Err(format!(
                "development setup journal exists in both legacy and current state: '{}'",
                current_runs.join(name).display()
            ));
        }
    }

    let provider_members = source_members
        .into_iter()
        .filter(|name| name != "_runs")
        .collect::<Vec<_>>();
    let mut moved = Vec::with_capacity(provider_members.len() + legacy_journals.len());
    for name in provider_members {
        move_entry(source.join(&name), destination.join(&name), &mut moved)?;
    }
    for name in legacy_journals {
        move_entry(
            legacy_runs.join(&name),
            current_runs.join(&name),
            &mut moved,
        )?;
    }

    if legacy_has_runs {
        if let Err(error) = fs::remove_dir(&legacy_runs) {
            rollback(&moved);
            return Err(format!(
                "cannot remove empty legacy development setup journals: {error}"
            ));
        }
    }
    if let Err(error) = fs::remove_dir(source) {
        if legacy_has_runs {
            let _ = fs::create_dir(&legacy_runs);
        }
        rollback(&moved);
        return Err(format!(
            "cannot remove empty legacy development setup: {error}"
        ));
    }
    Ok(())
}

fn move_entry(
    original: PathBuf,
    target: PathBuf,
    moved: &mut Vec<(PathBuf, PathBuf)>,
) -> Result<(), String> {
    if let Err(error) = fs::rename(&original, &target) {
        rollback(moved);
        return Err(format!(
            "cannot merge legacy development setup '{}' into '{}': {error}",
            original.display(),
            target.display()
        ));
    }
    moved.push((original, target));
    Ok(())
}

fn rollback(moved: &[(PathBuf, PathBuf)]) {
    for (original, target) in moved.iter().rev() {
        let _ = fs::rename(target, original);
    }
}

fn entry_names(path: &Path, subject: &str) -> Result<Vec<OsString>, String> {
    let mut names = fs::read_dir(path)
        .map_err(|error| format!("cannot inspect {subject}: {error}"))?
        .map(|entry| entry.map(|entry| entry.file_name()))
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("cannot inspect {subject}: {error}"))?;
    names.sort();
    Ok(names)
}

fn inspect_regular_tree(path: &Path, subject: &str) -> Result<(), String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("cannot inspect {subject} '{}': {error}", path.display()))?;
    if is_reparse(&metadata) || (!metadata.is_dir() && !metadata.is_file()) {
        return Err(format!(
            "{subject} must contain only regular filesystem entries: {}",
            path.display()
        ));
    }
    if metadata.is_dir() {
        let children = fs::read_dir(path)
            .map_err(|error| format!("cannot inspect {subject} '{}': {error}", path.display()))?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|error| format!("cannot inspect {subject} '{}': {error}", path.display()))?;
        for child in children {
            inspect_regular_tree(&child.path(), subject)?;
        }
    }
    Ok(())
}

fn require_regular_directory(path: &Path, subject: &str) -> Result<(), String> {
    let metadata =
        fs::symlink_metadata(path).map_err(|error| format!("cannot inspect {subject}: {error}"))?;
    if !metadata.is_dir() || is_reparse(&metadata) {
        return Err(format!("{subject} are not a regular directory"));
    }
    Ok(())
}

fn is_reparse(metadata: &fs::Metadata) -> bool {
    metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

fn conflicting_state(source: &Path, destination: &Path) -> String {
    format!(
        "legacy and current development setup state both exist: '{}' and '{}'",
        source.display(),
        destination.display()
    )
}
