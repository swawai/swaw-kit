use std::ffi::OsStr;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use windows_sys::Win32::Storage::FileSystem::{
    REPLACEFILE_IGNORE_MERGE_ERRORS, REPLACEFILE_WRITE_THROUGH, ReplaceFileW,
};

static NEXT_PUBLICATION: AtomicU64 = AtomicU64::new(0);

pub(crate) fn publish(path: &Path, content: &[u8]) -> io::Result<()> {
    let directory = path.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "publication path has no parent",
        )
    })?;
    let temporary = unique_sibling(directory, "tmp");

    let result = publish_inner(path, &temporary, content);
    let cleanup = cleanup(&temporary);
    result.and(cleanup)
}

fn publish_inner(path: &Path, temporary: &Path, content: &[u8]) -> io::Result<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(temporary)?;
    file.write_all(content)?;
    file.sync_all()?;
    drop(file);

    if !path.exists() {
        return fs::rename(temporary, path);
    }

    replace_file(path, temporary)
}

fn replace_file(path: &Path, temporary: &Path) -> io::Result<()> {
    let path = null_terminated(path.as_os_str());
    let temporary = null_terminated(temporary.as_os_str());
    let succeeded = unsafe {
        ReplaceFileW(
            path.as_ptr(),
            temporary.as_ptr(),
            std::ptr::null(),
            REPLACEFILE_IGNORE_MERGE_ERRORS | REPLACEFILE_WRITE_THROUGH,
            std::ptr::null(),
            std::ptr::null(),
        )
    };
    if succeeded == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn cleanup(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

fn unique_sibling(directory: &Path, suffix: &str) -> PathBuf {
    let sequence = NEXT_PUBLICATION.fetch_add(1, Ordering::Relaxed);
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    directory.join(format!(
        ".swawkit.{}.{timestamp}.{sequence}.{suffix}",
        std::process::id()
    ))
}

fn null_terminated(value: &OsStr) -> Vec<u16> {
    value.encode_wide().chain(std::iter::once(0)).collect()
}
