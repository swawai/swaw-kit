use std::fs::{self, OpenOptions};
use std::io::Read;
use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

use windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT;

use crate::command::{CommandError, CommandResult};

pub(super) const RELEASE_ID_LENGTH: usize = 64;
const SELECTOR_LENGTH: u64 = (RELEASE_ID_LENGTH + 1) as u64;

pub(super) fn read_release_selector(path: &Path, label: &str) -> CommandResult<String> {
    let bytes = read_regular_file(path, label, SELECTOR_LENGTH)?;
    if bytes.len() as u64 != SELECTOR_LENGTH || bytes.last() != Some(&b'\n') {
        return invalid(format!(
            "{label} '{}' must contain exactly one lowercase SHA-256 digest followed by LF",
            path.display()
        ));
    }
    let value = std::str::from_utf8(&bytes[..RELEASE_ID_LENGTH]).map_err(|error| {
        CommandError::new(format!(
            "{label} '{}' is not UTF-8: {error}",
            path.display()
        ))
    })?;
    if !is_release_id(value) {
        return invalid(format!(
            "{label} '{}' must contain exactly one lowercase SHA-256 digest followed by LF",
            path.display()
        ));
    }
    Ok(value.to_owned())
}

pub(super) fn is_release_id(value: &str) -> bool {
    value.len() == RELEASE_ID_LENGTH
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

pub(super) fn checked_directory(path: &Path, label: &str) -> CommandResult<PathBuf> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        CommandError::new(format!(
            "{label} is unavailable at '{}': {error}",
            path.display()
        ))
    })?;
    if !metadata.is_dir() || is_reparse_point(&metadata) {
        return invalid(format!(
            "{label} is not a regular directory: '{}'",
            path.display()
        ));
    }
    Ok(path.to_path_buf())
}

pub(super) fn read_regular_file(path: &Path, label: &str, maximum: u64) -> CommandResult<Vec<u8>> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(windows_sys::Win32::Storage::FileSystem::FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)
        .map_err(|error| {
            CommandError::new(format!(
                "{label} is unavailable at '{}': {error}",
                path.display()
            ))
        })?;
    let metadata = file.metadata().map_err(|error| {
        CommandError::new(format!(
            "cannot inspect {label} '{}': {error}",
            path.display()
        ))
    })?;
    if !metadata.is_file() || is_reparse_point(&metadata) || metadata.len() > maximum {
        return invalid(format!(
            "{label} is not a bounded regular file: '{}'",
            path.display()
        ));
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(maximum.saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(|error| {
            CommandError::new(format!("cannot read {label} '{}': {error}", path.display()))
        })?;
    if bytes.len() as u64 > maximum {
        return invalid(format!(
            "{label} is not a bounded regular file: '{}'",
            path.display()
        ));
    }
    Ok(bytes)
}

pub(super) fn is_reparse_point(metadata: &fs::Metadata) -> bool {
    metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

pub(super) fn invalid<T>(message: String) -> CommandResult<T> {
    Err(CommandError::new(message))
}
