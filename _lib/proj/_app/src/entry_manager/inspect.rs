use std::fs;
use std::os::windows::fs::MetadataExt;
use std::path::Path;

use windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT;

use crate::entry::{EntryId, EntryIdErrorKind};
use crate::runtime_release::RuntimeReleaseStore;

use super::launcher::{receipt_exists, validate_installed, validate_receipt};
use super::legacy::{legacy_record_exists, validate_legacy_record};
use super::model::EntryStatus;
use super::{EntryManagerError, EntryState, EntryTarget};

pub(super) fn inspect_target(target: &EntryTarget) -> Result<EntryState, EntryManagerError> {
    let entry_kind = path_kind(&target.entry_file);
    let data_kind = path_kind(&target.data_root);
    let paths = state_paths(target)?;

    if matches!(data_kind, PathKind::Missing) {
        return Ok(match entry_kind {
            PathKind::Missing => state(paths, EntryStatus::Available, None, None, vec![]),
            _ => state(
                paths,
                EntryStatus::Conflict,
                None,
                None,
                vec!["Entry Launcher exists without its DataRoot".to_owned()],
            ),
        });
    }
    if !matches!(data_kind, PathKind::RegularDirectory) {
        return Ok(state(
            paths,
            EntryStatus::Conflict,
            None,
            None,
            vec![format!(
                "Entry DataRoot is not a regular non-reparse directory: {}",
                target.data_root.display()
            )],
        ));
    }

    match EntryId::read(&target.data_root) {
        Ok(entry_id) => inspect_initialized(target, paths, entry_kind, entry_id),
        Err(error) if error.kind() == EntryIdErrorKind::Missing => {
            inspect_uninitialized(target, paths, entry_kind)
        }
        Err(error) => Ok(state(
            paths,
            EntryStatus::Conflict,
            None,
            None,
            vec![error.to_string()],
        )),
    }
}

fn inspect_initialized(
    target: &EntryTarget,
    paths: StatePaths,
    entry_kind: PathKind,
    entry_id: EntryId,
) -> Result<EntryState, EntryManagerError> {
    let release_id = match inspect_runtime(target) {
        Ok(value) => value,
        Err(issue) => {
            return Ok(state(
                paths,
                EntryStatus::Conflict,
                Some(entry_id.to_string()),
                None,
                vec![issue],
            ));
        }
    };
    if matches!(entry_kind, PathKind::Missing) {
        return Ok(match validate_receipt(&target.data_root, &target.name) {
            Ok(()) => state(
                paths,
                EntryStatus::Incomplete,
                Some(entry_id.to_string()),
                Some(release_id),
                vec!["Entry Launcher publication has not completed".to_owned()],
            ),
            Err(issue) => state(
                paths,
                EntryStatus::Conflict,
                Some(entry_id.to_string()),
                Some(release_id),
                vec![issue],
            ),
        });
    }
    if !matches!(entry_kind, PathKind::RegularFile) {
        return Ok(state(
            paths,
            EntryStatus::Conflict,
            Some(entry_id.to_string()),
            Some(release_id),
            vec!["Entry Launcher is not a regular non-reparse file".to_owned()],
        ));
    }
    match validate_installed(&target.data_root, &target.entry_file, &target.name) {
        Ok(()) => Ok(state(
            paths,
            EntryStatus::Ready,
            Some(entry_id.to_string()),
            Some(release_id),
            vec![],
        )),
        Err(issue) => Ok(state(
            paths,
            EntryStatus::Conflict,
            Some(entry_id.to_string()),
            Some(release_id),
            vec![issue],
        )),
    }
}

fn inspect_uninitialized(
    target: &EntryTarget,
    paths: StatePaths,
    entry_kind: PathKind,
) -> Result<EntryState, EntryManagerError> {
    if !legacy_record_exists(&target.data_root) {
        return Ok(state(
            paths,
            EntryStatus::Conflict,
            None,
            None,
            vec!["Entry DataRoot has neither entry.id nor valid legacy evidence".to_owned()],
        ));
    }
    if let Err(issue) = validate_legacy_record(&target.data_root, &target.name) {
        return Ok(state(paths, EntryStatus::Conflict, None, None, vec![issue]));
    }
    if !matches!(entry_kind, PathKind::Missing | PathKind::RegularFile) {
        return Ok(state(
            paths,
            EntryStatus::Conflict,
            None,
            None,
            vec!["legacy Entry Launcher is not a regular non-reparse file".to_owned()],
        ));
    }
    if receipt_exists(&target.data_root)
        && let Err(issue) = validate_receipt(&target.data_root, &target.name)
    {
        return Ok(state(
            paths,
            EntryStatus::Conflict,
            None,
            None,
            vec![format!("partial migration is inconsistent: {issue}")],
        ));
    }
    Ok(state(
        paths,
        EntryStatus::LegacyMigrationRequired,
        None,
        inspect_runtime(target).ok(),
        vec![],
    ))
}

fn inspect_runtime(target: &EntryTarget) -> Result<String, String> {
    let runtime_root = target.data_root.join("runtime");
    let home = target
        .data_root
        .parent()
        .and_then(Path::parent)
        .ok_or_else(|| "Entry DataRoot has no SWAWKIT_HOME ancestor".to_owned())?;
    let store = RuntimeReleaseStore::open(&runtime_root, home)
        .map_err(|error| format!("Entry Runtime is invalid: {error}"))?;
    let release_id = store
        .selected_release_id()
        .map_err(|error| format!("Entry Runtime selector is invalid: {error}"))?;
    store
        .validate(&release_id)
        .map_err(|error| format!("selected Entry Runtime Release is invalid: {error}"))?;
    Ok(release_id)
}

pub(super) fn conflict_state(
    target: &EntryTarget,
    issues: Vec<String>,
) -> Result<EntryState, EntryManagerError> {
    Ok(state(
        state_paths(target)?,
        EntryStatus::Conflict,
        None,
        None,
        issues,
    ))
}

struct StatePaths {
    name: String,
    entry_file: String,
    data_root: String,
}

fn state_paths(target: &EntryTarget) -> Result<StatePaths, EntryManagerError> {
    Ok(StatePaths {
        name: target.name.clone(),
        entry_file: unicode_path(&target.entry_file, "Entry Launcher")?,
        data_root: unicode_path(&target.data_root, "Entry DataRoot")?,
    })
}

fn state(
    paths: StatePaths,
    status: EntryStatus,
    entry_id: Option<String>,
    release_id: Option<String>,
    issues: Vec<String>,
) -> EntryState {
    EntryState {
        entry_name: paths.name,
        entry_file: paths.entry_file,
        data_root: paths.data_root,
        status,
        entry_id,
        release_id,
        issues,
    }
}

fn unicode_path(path: &Path, label: &str) -> Result<String, EntryManagerError> {
    path.to_str().map(str::to_owned).ok_or_else(|| {
        EntryManagerError::corrupt(format!(
            "{label} path is not valid Unicode: {}",
            path.display()
        ))
    })
}

#[derive(Clone, Copy)]
enum PathKind {
    Missing,
    RegularFile,
    RegularDirectory,
    Unsafe,
}

fn path_kind(path: &Path) -> PathKind {
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => PathKind::Missing,
        Err(_) => PathKind::Unsafe,
        Ok(metadata) if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 => {
            PathKind::Unsafe
        }
        Ok(metadata) if metadata.is_file() => PathKind::RegularFile,
        Ok(metadata) if metadata.is_dir() => PathKind::RegularDirectory,
        Ok(_) => PathKind::Unsafe,
    }
}
