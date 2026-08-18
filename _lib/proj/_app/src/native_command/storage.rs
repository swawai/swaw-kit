use std::fs;
use std::os::windows::fs::MetadataExt;
use std::path::{Component, Path, PathBuf};

use sha2::{Digest, Sha256};
use windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT;

use crate::command::{CommandError, CommandResult};

pub(super) const RELEASE_ID_LENGTH: usize = 64;

pub(super) fn read_release_selector(path: &Path, label: &str) -> CommandResult<String> {
    let bytes = read_regular_file(path, label)?;
    let value = std::str::from_utf8(&bytes).map_err(|error| {
        CommandError::new(format!(
            "{label} '{}' is not UTF-8: {error}",
            path.display()
        ))
    })?;
    let release_id = value.strip_suffix('\n').unwrap_or(value);
    if !is_release_id(release_id) {
        return invalid(format!(
            "{label} '{}' must contain one lowercase SHA-256 digest",
            path.display()
        ));
    }
    Ok(release_id.to_owned())
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

pub(super) fn read_regular_file(path: &Path, label: &str) -> CommandResult<Vec<u8>> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        CommandError::new(format!(
            "{label} is unavailable at '{}': {error}",
            path.display()
        ))
    })?;
    if !metadata.is_file() || is_reparse_point(&metadata) {
        return invalid(format!(
            "{label} is not a regular file: '{}'",
            path.display()
        ));
    }
    fs::read(path).map_err(|error| {
        CommandError::new(format!("cannot read {label} '{}': {error}", path.display()))
    })
}

pub(super) fn is_reparse_point(metadata: &fs::Metadata) -> bool {
    metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

pub(super) fn hex_sha256(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut value = String::with_capacity(RELEASE_ID_LENGTH);
    for byte in digest {
        use std::fmt::Write;
        write!(&mut value, "{byte:02x}").expect("write to String");
    }
    value
}

pub(super) fn ensure_data_root(path: &Path) -> Result<(), String> {
    match fs::create_dir(path) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let parent = path
                .parent()
                .ok_or_else(|| "Entry DataRoot has no parent directory".to_owned())?;
            checked_directory(parent, "Entry DataRoot parent")
                .map_err(|error| error.to_string())?;
            fs::create_dir(path).map_err(|error| {
                format!("cannot create Entry DataRoot '{}': {error}", path.display())
            })?;
        }
        Err(error) => {
            return Err(format!(
                "cannot create Entry DataRoot '{}': {error}",
                path.display()
            ));
        }
    }
    checked_directory(path, "Entry DataRoot")
        .map(|_| ())
        .map_err(|error| error.to_string())
}

pub(super) fn ensure_descendant(
    root: &Path,
    target: &Path,
    label: &str,
) -> Result<PathBuf, String> {
    let relative = target
        .strip_prefix(root)
        .map_err(|_| format!("{label} escapes its controlled root"))?;
    let mut current = root.to_path_buf();
    checked_directory(&current, label).map_err(|error| error.to_string())?;
    for component in relative.components() {
        let Component::Normal(segment) = component else {
            return Err(format!("{label} contains an unsafe path component"));
        };
        current.push(segment);
        match fs::create_dir(&current) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(error) => {
                return Err(format!(
                    "cannot create {label} '{}': {error}",
                    current.display()
                ));
            }
        }
        checked_directory(&current, label).map_err(|error| error.to_string())?;
    }
    Ok(current)
}

pub(super) fn invalid<T>(message: String) -> CommandResult<T> {
    Err(CommandError::new(message))
}
