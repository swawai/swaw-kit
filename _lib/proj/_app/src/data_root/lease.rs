use std::fs::{File, OpenOptions};
use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;

use windows_sys::Win32::Storage::FileSystem::{
    FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT,
    FILE_SHARE_READ, FILE_SHARE_WRITE,
};

pub(crate) struct DataRootBindingLease {
    _directory: File,
}

impl DataRootBindingLease {
    pub(crate) fn acquire(data_root: &Path) -> Result<Self, DataRootLeaseError> {
        let directory = OpenOptions::new()
            .read(true)
            .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE)
            .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
            .open(data_root)
            .map_err(|error| lease_error("pin Entry DataRoot", data_root, error))?;
        let metadata = directory
            .metadata()
            .map_err(|error| lease_error("inspect pinned Entry DataRoot", data_root, error))?;
        if !metadata.is_dir() || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            return Err(DataRootLeaseError::new(format!(
                "Entry DataRoot must be a regular non-reparse directory: {}",
                data_root.display()
            )));
        }

        Ok(Self {
            _directory: directory,
        })
    }
}

fn lease_error(action: &str, path: &Path, error: std::io::Error) -> DataRootLeaseError {
    DataRootLeaseError::new(format!("cannot {action} '{}': {error}", path.display()))
}

#[derive(Debug)]
pub(crate) struct DataRootLeaseError {
    message: String,
}

impl DataRootLeaseError {
    fn new(message: String) -> Self {
        Self { message }
    }
}

impl std::fmt::Display for DataRootLeaseError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for DataRootLeaseError {}
