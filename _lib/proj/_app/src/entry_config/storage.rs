use std::fs::{self, OpenOptions};
use std::io::Read;
use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;

use sha2::{Digest, Sha256};
use windows_sys::Win32::Storage::FileSystem::{
    FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_OPEN_REPARSE_POINT,
};

use super::{
    ENTRY_CONFIG_MAX_BYTES, EntryConfigError, EntryConfigRecord, error::EntryConfigReadError,
};

pub(super) fn read_record(
    path: &Path,
) -> Result<(EntryConfigRecord, String), EntryConfigReadError> {
    let content = read_bounded_file(path, "entry config")?;
    let revision = revision(&content);
    serde_json::from_slice(&content)
        .map(|record| (record, revision.clone()))
        .map_err(|error| {
            EntryConfigReadError::with_revision(
                format!("invalid entry config JSON: {error}"),
                revision,
            )
        })
}

pub(super) fn read_input_record(path: &Path) -> Result<EntryConfigRecord, EntryConfigError> {
    let content = read_bounded_file(path, "Entry Config input")?;
    serde_json::from_slice(&content).map_err(|error| {
        EntryConfigError::new(format!(
            "invalid Entry Config JSON '{}': {error}",
            path.display()
        ))
    })
}

pub(super) fn revision(content: &[u8]) -> String {
    format!("sha256-{:x}", Sha256::digest(content))
}

fn read_bounded_file(path: &Path, label: &str) -> Result<Vec<u8>, EntryConfigError> {
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)
        .map_err(|error| {
            EntryConfigError::new(format!("cannot read {label} '{}': {error}", path.display()))
        })?;
    let metadata = file.metadata().map_err(|error| {
        EntryConfigError::new(format!(
            "cannot inspect {label} '{}': {error}",
            path.display()
        ))
    })?;
    if !metadata.is_file()
        || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
        || metadata.len() > ENTRY_CONFIG_MAX_BYTES
    {
        return Err(EntryConfigError::new(format!(
            "{label} must be a regular non-reparse file no larger than {ENTRY_CONFIG_MAX_BYTES} bytes: {}",
            path.display()
        )));
    }

    let initial_length = metadata.len();
    let mut content = Vec::with_capacity(initial_length as usize);
    file.by_ref()
        .take(ENTRY_CONFIG_MAX_BYTES + 1)
        .read_to_end(&mut content)
        .map_err(|error| {
            EntryConfigError::new(format!("cannot read {label} '{}': {error}", path.display()))
        })?;
    let final_length = file
        .metadata()
        .map_err(|error| {
            EntryConfigError::new(format!(
                "cannot re-inspect {label} '{}': {error}",
                path.display()
            ))
        })?
        .len();
    if content.len() as u64 > ENTRY_CONFIG_MAX_BYTES {
        return Err(EntryConfigError::new(format!(
            "{label} exceeds its {ENTRY_CONFIG_MAX_BYTES}-byte limit while being read: {}",
            path.display()
        )));
    }
    if final_length != initial_length || final_length != content.len() as u64 {
        return Err(EntryConfigError::new(format!(
            "{label} changed while being read: {}",
            path.display()
        )));
    }
    Ok(content)
}

pub(super) fn validate_data_root(data_root: &Path) -> Result<(), EntryConfigError> {
    let metadata = fs::symlink_metadata(data_root).map_err(|error| {
        EntryConfigError::new(format!(
            "cannot inspect Entry Config DataRoot '{}': {error}",
            data_root.display()
        ))
    })?;
    if !metadata.is_dir() || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(EntryConfigError::new(format!(
            "Entry Config DataRoot must be a regular directory: {}",
            data_root.display()
        )));
    }
    Ok(())
}

pub(super) fn validate_publication_target(path: &Path) -> Result<(), EntryConfigError> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(EntryConfigError::new(format!(
                "cannot inspect entry config '{}': {error}",
                path.display()
            )));
        }
    };
    if !metadata.is_file() || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(EntryConfigError::new(format!(
            "entry config must be a regular file: {}",
            path.display()
        )));
    }
    Ok(())
}
