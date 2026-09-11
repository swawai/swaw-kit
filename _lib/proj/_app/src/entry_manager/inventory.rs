use std::collections::BTreeMap;
use std::fs;
use std::os::windows::fs::MetadataExt;
use std::path::{Path, PathBuf};

use super::inspect::conflict_state;
use super::name::validate_name;
use super::{EntryManager, EntryManagerError, EntryState, EntryTarget};

const MAX_INVENTORY_CANDIDATES: usize = 512;

#[derive(Default)]
struct Candidate {
    entry_paths: Vec<PathBuf>,
    data_paths: Vec<PathBuf>,
}

pub(super) fn read_inventory(
    manager: &EntryManager<'_>,
) -> Result<Vec<EntryState>, EntryManagerError> {
    let mut candidates = BTreeMap::<String, Candidate>::new();
    collect_entry_files(&manager.context.swawkit_home, &mut candidates)?;
    collect_data_roots(&manager.context.swawkit_home.join("data"), &mut candidates)?;
    if candidates.len() > MAX_INVENTORY_CANDIDATES {
        return Err(EntryManagerError::corrupt(format!(
            "Entry inventory exceeds its {MAX_INVENTORY_CANDIDATES}-candidate limit"
        )));
    }

    candidates
        .into_iter()
        .map(|(name, candidate)| {
            if let Err(error) = validate_name(&name) {
                return raw_conflict_state(manager, name, candidate, error.to_string());
            }
            let target = EntryTarget::parse(manager.context, &name)?;
            let mut issues = Vec::new();
            inspect_candidate_paths(
                &candidate.entry_paths,
                &target.entry_file,
                "Entry Launcher",
                &mut issues,
            );
            inspect_candidate_paths(
                &candidate.data_paths,
                &target.data_root,
                "Entry DataRoot",
                &mut issues,
            );
            if issues.is_empty() {
                super::inspect::inspect_target(&target)
            } else {
                conflict_state(&target, issues)
            }
        })
        .collect()
}

fn collect_entry_files(
    home: &Path,
    candidates: &mut BTreeMap<String, Candidate>,
) -> Result<(), EntryManagerError> {
    for item in
        fs::read_dir(home).map_err(|error| EntryManagerError::io("read SWAWKIT_HOME", error))?
    {
        let item =
            item.map_err(|error| EntryManagerError::io("read a SWAWKIT_HOME member", error))?;
        let Some(file_name) = item.file_name().to_str().map(str::to_owned) else {
            continue;
        };
        let lower = file_name.to_ascii_lowercase();
        let Some(name) = lower.strip_suffix(".exe") else {
            continue;
        };
        if name.is_empty() || name == "swawkit" {
            continue;
        }
        candidates
            .entry(name.to_owned())
            .or_default()
            .entry_paths
            .push(item.path());
        bounded(candidates)?;
    }
    Ok(())
}

fn collect_data_roots(
    data: &Path,
    candidates: &mut BTreeMap<String, Candidate>,
) -> Result<(), EntryManagerError> {
    for item in fs::read_dir(data)
        .map_err(|error| EntryManagerError::io("read the Entry data directory", error))?
    {
        let item =
            item.map_err(|error| EntryManagerError::io("read an Entry data member", error))?;
        let Some(file_name) = item.file_name().to_str().map(str::to_owned) else {
            continue;
        };
        let lower = file_name.to_ascii_lowercase();
        let Some(name) = lower.strip_prefix("proj.") else {
            continue;
        };
        if name.is_empty() || name == "swawkit" {
            continue;
        }
        candidates
            .entry(name.to_owned())
            .or_default()
            .data_paths
            .push(item.path());
        bounded(candidates)?;
    }
    Ok(())
}

fn raw_conflict_state(
    manager: &EntryManager<'_>,
    name: String,
    candidate: Candidate,
    reason: String,
) -> Result<EntryState, EntryManagerError> {
    let expected_entry = manager.context.swawkit_home.join(format!("{name}.exe"));
    let expected_data = manager
        .context
        .swawkit_home
        .join("data")
        .join(format!("proj.{name}"));
    let entry_file = expected_entry.to_str().ok_or_else(|| {
        EntryManagerError::corrupt("non-canonical Entry Launcher path is not valid Unicode")
    })?;
    let data_root = expected_data.to_str().ok_or_else(|| {
        EntryManagerError::corrupt("non-canonical Entry DataRoot path is not valid Unicode")
    })?;
    let mut issues = vec![reason];
    for path in candidate
        .entry_paths
        .iter()
        .chain(candidate.data_paths.iter())
    {
        issues.push(format!(
            "non-canonical Entry inventory member: {}",
            path.display()
        ));
    }
    Ok(EntryState {
        entry_name: name,
        entry_file: entry_file.to_owned(),
        data_root: data_root.to_owned(),
        status: super::EntryStatus::Conflict,
        release_id: None,
        issues,
    })
}

fn bounded(candidates: &BTreeMap<String, Candidate>) -> Result<(), EntryManagerError> {
    let count = candidates
        .values()
        .map(|candidate| candidate.entry_paths.len() + candidate.data_paths.len())
        .sum::<usize>();
    if count > MAX_INVENTORY_CANDIDATES {
        Err(EntryManagerError::corrupt(format!(
            "Entry inventory exceeds its {MAX_INVENTORY_CANDIDATES}-candidate limit"
        )))
    } else {
        Ok(())
    }
}

fn inspect_candidate_paths(
    paths: &[PathBuf],
    expected: &Path,
    label: &str,
    issues: &mut Vec<String>,
) {
    if paths.len() > 1 {
        issues.push(format!("{label} has a case-insensitive name collision"));
    }
    for path in paths {
        if path != expected {
            issues.push(format!("{label} name is non-canonical: {}", path.display()));
        }
        match fs::symlink_metadata(path) {
            Ok(metadata)
                if metadata.file_attributes()
                    & windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT
                    != 0 =>
            {
                issues.push(format!(
                    "{label} cannot be a reparse point: {}",
                    path.display()
                ));
            }
            Err(error) => issues.push(format!(
                "cannot inspect {label} '{}': {error}",
                path.display()
            )),
            _ => {}
        }
    }
}
