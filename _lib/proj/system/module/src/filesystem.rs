use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::windows::ffi::OsStrExt;
use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;
const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
const MOVEFILE_REPLACE_EXISTING: u32 = 0x1;
const MOVEFILE_WRITE_THROUGH: u32 = 0x8;
static NEXT_TOKEN: AtomicU64 = AtomicU64::new(0);

#[link(name = "kernel32")]
unsafe extern "system" {
    fn MoveFileExW(existing: *const u16, replacement: *const u16, flags: u32) -> i32;
}

pub(crate) fn regular_directory(path: &Path, label: &str) -> Result<(), String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("cannot inspect {label} '{}': {error}", path.display()))?;
    if !metadata.is_dir() || is_reparse(&metadata) {
        return Err(format!(
            "{label} must be a regular directory: {}",
            path.display()
        ));
    }
    Ok(())
}

pub(crate) fn checked_directory(
    root: &Path,
    segments: impl IntoIterator<Item = impl AsRef<str>>,
    label: &str,
) -> Result<PathBuf, String> {
    regular_directory(root, label)?;
    let mut current = root.to_path_buf();
    for segment in segments {
        validate_segment(segment.as_ref(), label)?;
        current.push(segment.as_ref());
        regular_directory(&current, label)?;
    }
    Ok(current)
}

pub(crate) fn ensure_directory(
    root: &Path,
    segments: impl IntoIterator<Item = impl AsRef<str>>,
    label: &str,
) -> Result<PathBuf, String> {
    regular_directory(root, label)?;
    let mut current = root.to_path_buf();
    for segment in segments {
        validate_segment(segment.as_ref(), label)?;
        current.push(segment.as_ref());
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
        regular_directory(&current, label)?;
    }
    Ok(current)
}

pub(crate) fn read_regular_file(path: &Path, label: &str, maximum: u64) -> Result<Vec<u8>, String> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)
        .map_err(|error| format!("cannot open {label} '{}': {error}", path.display()))?;
    let metadata = file
        .metadata()
        .map_err(|error| format!("cannot inspect {label} '{}': {error}", path.display()))?;
    if !metadata.is_file() || is_reparse(&metadata) || metadata.len() > maximum {
        return Err(format!(
            "{label} must be a bounded regular file: {}",
            path.display()
        ));
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(maximum.saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(|error| format!("cannot read {label} '{}': {error}", path.display()))?;
    if bytes.len() as u64 > maximum {
        return Err(format!(
            "{label} must be a bounded regular file: {}",
            path.display()
        ));
    }
    Ok(bytes)
}

pub(crate) fn write_new(path: &Path, bytes: &[u8], label: &str) -> Result<(), String> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)
        .map_err(|error| format!("cannot create {label} '{}': {error}", path.display()))?;
    file.write_all(bytes)
        .and_then(|()| file.sync_all())
        .map_err(|error| format!("cannot write {label} '{}': {error}", path.display()))
}

pub(crate) fn atomic_replace(path: &Path, bytes: &[u8], label: &str) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| format!("{label} has no parent: {}", path.display()))?;
    regular_directory(parent, &format!("{label} parent"))?;
    if entry_exists(path, label)? {
        let metadata = fs::symlink_metadata(path)
            .map_err(|error| format!("cannot inspect {label} '{}': {error}", path.display()))?;
        if !metadata.is_file() || is_reparse(&metadata) {
            return Err(format!("{label} is unsafe: {}", path.display()));
        }
    }
    let stage = parent.join(format!(".{}.{}.tmp", file_name(path)?, unique_token()));
    write_new(&stage, bytes, &format!("staged {label}"))?;
    let existing = wide_null(&stage);
    let replacement = wide_null(path);
    // SAFETY: both strings are owned, NUL terminated absolute or parent-owned
    // paths. The operation is an atomic same-directory replacement.
    let result = unsafe {
        MoveFileExW(
            existing.as_ptr(),
            replacement.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if result == 0 {
        let error = std::io::Error::last_os_error();
        let _ = fs::remove_file(&stage);
        return Err(format!(
            "cannot replace {label} '{}': {error}",
            path.display()
        ));
    }
    Ok(())
}

pub(crate) fn remove_tree(path: &Path) {
    if let Ok(metadata) = fs::symlink_metadata(path) {
        if metadata.is_dir() && !is_reparse(&metadata) {
            let _ = fs::remove_dir_all(path);
        } else {
            let _ = fs::remove_file(path);
        }
    }
}

pub(crate) fn entry_exists(path: &Path, label: &str) -> Result<bool, String> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(format!(
            "cannot inspect {label} '{}': {error}",
            path.display()
        )),
    }
}

pub(crate) fn unique_token() -> String {
    let tick = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let sequence = NEXT_TOKEN.fetch_add(1, Ordering::Relaxed);
    format!("{:x}{tick:x}{sequence:x}", std::process::id())
}

pub(crate) struct ExclusiveFileLock {
    _file: File,
}

impl ExclusiveFileLock {
    pub(crate) fn acquire(path: &Path, timeout: Duration) -> Result<Self, String> {
        let started = Instant::now();
        loop {
            match OpenOptions::new()
                .read(true)
                .write(true)
                .create(true)
                .share_mode(0)
                .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
                .open(path)
            {
                Ok(file) => {
                    let metadata = file.metadata().map_err(|error| {
                        format!("cannot inspect build lock '{}': {error}", path.display())
                    })?;
                    if !metadata.is_file() || is_reparse(&metadata) {
                        return Err(format!("build lock is unsafe: {}", path.display()));
                    }
                    return Ok(Self { _file: file });
                }
                Err(error)
                    if matches!(error.raw_os_error(), Some(32 | 33))
                        && started.elapsed() < timeout =>
                {
                    std::thread::sleep(Duration::from_millis(50));
                }
                Err(error) => {
                    return Err(format!(
                        "cannot acquire build lock '{}': {error}",
                        path.display()
                    ));
                }
            }
        }
    }
}

pub(crate) fn is_reparse(metadata: &fs::Metadata) -> bool {
    metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

fn validate_segment(value: &str, label: &str) -> Result<(), String> {
    if value.is_empty() || matches!(value, "." | "..") || value.contains(['/', '\\']) {
        Err(format!("unsafe {label} path segment '{value}'"))
    } else {
        Ok(())
    }
}

fn file_name(path: &Path) -> Result<String, String> {
    path.file_name()
        .and_then(|value| value.to_str())
        .map(str::to_owned)
        .ok_or_else(|| format!("path has no Unicode file name: {}", path.display()))
}

fn wide_null(path: &Path) -> Vec<u16> {
    path.as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}
