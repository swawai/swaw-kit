use std::fs::{self, OpenOptions};
use std::io::{self, Read};
use std::os::windows::ffi::OsStrExt;
use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;

use sha2::{Digest, Sha256};
use windows_sys::Win32::Storage::FileSystem::{
    FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_READ,
};

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct InstanceKey(String);

impl InstanceKey {
    pub fn derive(data_root: &Path) -> io::Result<Self> {
        regular_directory(data_root, "Entry DataRoot")?;
        let canonical = fs::canonicalize(data_root)?;
        if !canonical.is_absolute() {
            return Err(invalid_data("canonical Entry DataRoot is not absolute"));
        }
        regular_directory(&canonical, "canonical Entry DataRoot")?;
        Ok(Self(hash_instance_key(&canonical)))
    }

    pub fn parse(value: impl Into<String>) -> io::Result<Self> {
        let value = value.into();
        if !is_sha256(&value) {
            return Err(invalid_data("Host Instance key is invalid"));
        }
        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

pub(super) fn hash_instance_key(canonical_data_root: &Path) -> String {
    let mut digest = Sha256::new();
    for unit in canonical_data_root.as_os_str().encode_wide() {
        digest.update(unit.to_le_bytes());
    }
    format!("{:x}", digest.finalize())
}

pub(super) fn read_regular_file(path: &Path, maximum: u64) -> io::Result<Vec<u8>> {
    let mut file = OpenOptions::new()
        .read(true)
        // Hold a short read lease that prevents replacement or equal-length
        // mutation from becoming invisible to the length checks below.
        .share_mode(FILE_SHARE_READ)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file()
        || is_reparse(&metadata)
        || metadata.len() == 0
        || metadata.len() > maximum
    {
        return Err(invalid_data(format!(
            "Host runtime state must be a bounded regular file: {}",
            path.display()
        )));
    }
    let initial_length = metadata.len();
    let mut bytes = Vec::with_capacity(initial_length as usize);
    Read::by_ref(&mut file)
        .take(maximum.saturating_add(1))
        .read_to_end(&mut bytes)?;
    let final_length = file.metadata()?.len();
    if bytes.len() as u64 > maximum
        || final_length != initial_length
        || final_length != bytes.len() as u64
    {
        return Err(invalid_data(format!(
            "Host runtime state changed or exceeded its bound while being read: {}",
            path.display()
        )));
    }
    Ok(bytes)
}

pub(super) fn regular_directory(path: &Path, label: &str) -> io::Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_dir() || is_reparse(&metadata) {
        return Err(invalid_data(format!(
            "{label} must be a regular non-reparse directory: {}",
            path.display()
        )));
    }
    Ok(())
}

pub(super) fn is_reparse(metadata: &fs::Metadata) -> bool {
    metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

pub(super) fn is_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn invalid_data(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}
