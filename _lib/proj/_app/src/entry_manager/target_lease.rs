use std::fs::{File, OpenOptions};
use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;

use windows_sys::Win32::Storage::FileSystem::{
    FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT,
    FILE_SHARE_READ, FILE_SHARE_WRITE,
};

use super::EntryManagerError;

/// Pins an uninitialized or newly staged target DataRoot during its commit.
///
/// Omitting FILE_SHARE_DELETE prevents a checked directory from being renamed
/// or replaced while mutation code continues to address its children by path.
pub(super) struct TargetDataRootLease {
    _directory: File,
}

impl TargetDataRootLease {
    pub(super) fn acquire(data_root: &Path) -> Result<Self, EntryManagerError> {
        let directory = OpenOptions::new()
            .read(true)
            .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE)
            .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
            .open(data_root)
            .map_err(|error| EntryManagerError::io("pin the target Entry DataRoot", error))?;
        let metadata = directory
            .metadata()
            .map_err(|error| EntryManagerError::io("inspect the pinned Entry DataRoot", error))?;
        if !metadata.is_dir() || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            return Err(EntryManagerError::conflict(format!(
                "target Entry DataRoot must be a regular non-reparse directory: {}",
                data_root.display()
            )));
        }
        Ok(Self {
            _directory: directory,
        })
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::sync::atomic::{AtomicU64, Ordering};

    use super::*;

    static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

    #[test]
    fn lease_blocks_directory_rename_and_removal_until_drop() {
        let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let parent = std::env::temp_dir().join(format!(
            "swawkit-target-data-root-lease-{}-{sequence}",
            std::process::id()
        ));
        let data_root = parent.join("proj.test");
        let renamed = parent.join("proj.renamed");
        fs::create_dir_all(&data_root).unwrap();

        let lease = TargetDataRootLease::acquire(&data_root).unwrap();
        assert!(fs::rename(&data_root, &renamed).is_err());
        assert!(fs::remove_dir(&data_root).is_err());
        drop(lease);

        fs::rename(&data_root, &renamed).unwrap();
        fs::remove_dir(&renamed).unwrap();
        fs::remove_dir(&parent).unwrap();
    }
}
