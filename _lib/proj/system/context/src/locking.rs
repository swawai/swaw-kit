use std::fs::{self, File, OpenOptions};
use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;
use std::thread;
use std::time::Duration;

use windows_sys::Win32::Storage::FileSystem::{
    FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_OPEN_REPARSE_POINT,
};

use crate::error::{ContextError, ContextResult};

const ATTEMPTS: usize = 100;
const RETRY_DELAY: Duration = Duration::from_millis(50);

pub(crate) struct ContextLock {
    _file: File,
}

impl ContextLock {
    pub(crate) fn acquire(context_root: &Path) -> ContextResult<Self> {
        let lock_root = context_root.join("_locks");
        match fs::create_dir(&lock_root) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(error) => {
                return Err(ContextError::new(format!(
                    "cannot create Context lock directory '{}': {error}",
                    lock_root.display()
                )));
            }
        }
        validate_directory(&lock_root)?;
        let path = lock_root.join("context.lock");
        for attempt in 0..ATTEMPTS {
            match OpenOptions::new()
                .read(true)
                .write(true)
                .create(true)
                .share_mode(0)
                .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
                .open(&path)
            {
                Ok(file) => {
                    let metadata = file.metadata().map_err(|error| {
                        ContextError::new(format!(
                            "cannot inspect Context lock '{}': {error}",
                            path.display()
                        ))
                    })?;
                    if !metadata.is_file()
                        || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
                    {
                        return Err(ContextError::new(format!(
                            "Context lock must be a regular file: {}",
                            path.display()
                        )));
                    }
                    return Ok(Self { _file: file });
                }
                Err(_) if attempt + 1 < ATTEMPTS => thread::sleep(RETRY_DELAY),
                Err(error) => {
                    return Err(ContextError::new(format!(
                        "timed out waiting for Context lock '{}': {error}",
                        path.display()
                    )));
                }
            }
        }
        unreachable!("at least one lock attempt is required")
    }
}

fn validate_directory(path: &Path) -> ContextResult<()> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        ContextError::new(format!(
            "cannot inspect Context lock directory '{}': {error}",
            path.display()
        ))
    })?;
    if !metadata.is_dir() || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        Err(ContextError::new(format!(
            "Context lock directory must be a regular directory: {}",
            path.display()
        )))
    } else {
        Ok(())
    }
}
