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

    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)?;
    let prepared = file.write_all(content).and_then(|()| file.sync_all());
    drop(file);
    if let Err(error) = prepared {
        let _ = cleanup(&temporary);
        return Err(error);
    }

    let committed = if path.exists() {
        replace_file(path, &temporary)
    } else {
        fs::rename(&temporary, path)
    };
    committed.map_err(|error| commit_error(path, &temporary, error))
}

fn commit_error(path: &Path, temporary: &Path, error: io::Error) -> io::Error {
    io::Error::new(
        error.kind(),
        format!(
            "cannot commit atomic publication to '{}': {error}; recovery temporary: '{}'",
            path.display(),
            temporary.display()
        ),
    )
}

fn replace_file(path: &Path, temporary: &Path) -> io::Result<()> {
    let path = canonical_sibling(path)?;
    let temporary = canonical_sibling(temporary)?;
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

fn canonical_sibling(path: &Path) -> io::Result<PathBuf> {
    let directory = path.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "publication path has no parent",
        )
    })?;
    let name = path.file_name().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "publication path has no file name",
        )
    })?;
    Ok(fs::canonicalize(directory)?.join(name))
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
