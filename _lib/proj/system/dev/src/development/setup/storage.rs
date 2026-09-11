use std::fs::{self, File, OpenOptions};
use std::io::{self, Read};
use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Component, Path, PathBuf};
use std::thread;
use std::time::Duration;

use windows_sys::Win32::Foundation::{ERROR_LOCK_VIOLATION, ERROR_SHARING_VIOLATION};
use windows_sys::Win32::Storage::FileSystem::{
    FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_DELETE, FILE_SHARE_READ,
};

pub(crate) struct ExclusiveFileLock {
    _file: File,
}

impl ExclusiveFileLock {
    pub(crate) fn acquire(path: &Path, timeout: Duration) -> io::Result<Self> {
        let parent = path.parent().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "lock path has no parent")
        })?;
        regular_directory(parent, "setup lock directory")?;
        let started = std::time::Instant::now();
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
                    let metadata = file.metadata()?;
                    if !metadata.is_file() || is_reparse(&metadata) {
                        return Err(unsafe_path("setup lock", path));
                    }
                    return Ok(Self { _file: file });
                }
                Err(error) if is_lock_contention(&error) && started.elapsed() < timeout => {
                    thread::sleep(Duration::from_millis(50));
                }
                Err(error) if is_lock_contention(&error) => {
                    return Err(io::Error::new(
                        io::ErrorKind::TimedOut,
                        format!("timed out waiting for setup lock '{}'", path.display()),
                    ));
                }
                Err(error) => return Err(error),
            }
        }
    }
}

pub(crate) fn ensure_directory_chain(
    root: &Path,
    components: &[&str],
    subject: &str,
) -> io::Result<PathBuf> {
    regular_directory(root, subject)?;
    let mut path = root.to_path_buf();
    for component in components {
        if !matches!(
            Path::new(component)
                .components()
                .collect::<Vec<_>>()
                .as_slice(),
            [Component::Normal(_)]
        ) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("unsafe {subject} segment '{component}'"),
            ));
        }
        path.push(component);
        match fs::create_dir(&path) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error),
        }
        regular_directory(&path, subject)?;
    }
    Ok(path)
}

pub(super) fn existing_directory_chain(
    root: &Path,
    components: &[&str],
    subject: &str,
) -> io::Result<PathBuf> {
    regular_directory(root, subject)?;
    let mut path = root.to_path_buf();
    for component in components {
        if !matches!(
            Path::new(component)
                .components()
                .collect::<Vec<_>>()
                .as_slice(),
            [Component::Normal(_)]
        ) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("unsafe {subject} segment '{component}'"),
            ));
        }
        path.push(component);
        regular_directory(&path, subject)?;
    }
    Ok(path)
}

pub(super) fn regular_directory(path: &Path, subject: &str) -> io::Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_dir() || is_reparse(&metadata) {
        return Err(unsafe_path(subject, path));
    }
    Ok(())
}

pub(crate) fn regular_file_or_missing(path: &Path, subject: &str) -> io::Result<bool> {
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error),
        Ok(metadata) if metadata.is_file() && !is_reparse(&metadata) => Ok(true),
        Ok(_) => Err(unsafe_path(subject, path)),
    }
}

pub(crate) fn read_replaceable_bounded(
    path: &Path,
    subject: &str,
    maximum: u64,
) -> io::Result<Vec<u8>> {
    let file = OpenOptions::new()
        .read(true)
        .share_mode(FILE_SHARE_READ | FILE_SHARE_DELETE)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)?;
    read_replaceable_bounded_from_file(file, path, subject, maximum, |_| Ok(()))
}

fn read_replaceable_bounded_from_file(
    mut file: File,
    path: &Path,
    subject: &str,
    maximum: u64,
    before_read: impl FnOnce(&File) -> io::Result<()>,
) -> io::Result<Vec<u8>> {
    let initial_metadata = file.metadata()?;
    if !initial_metadata.is_file() || is_reparse(&initial_metadata) {
        return Err(unsafe_path(subject, path));
    }
    if initial_metadata.len() > maximum {
        return Err(size_limit_exceeded(subject));
    }

    let initial_length = initial_metadata.len();
    before_read(&file)?;
    let mut content = Vec::with_capacity(initial_length as usize);
    file.by_ref()
        .take(maximum.saturating_add(1))
        .read_to_end(&mut content)?;
    if content.len() as u64 > maximum {
        return Err(size_limit_exceeded(subject));
    }

    let final_metadata = file.metadata()?;
    if !final_metadata.is_file() || is_reparse(&final_metadata) {
        return Err(unsafe_path(subject, path));
    }
    if final_metadata.len() > maximum {
        return Err(size_limit_exceeded(subject));
    }
    if final_metadata.len() != initial_length || content.len() as u64 != initial_length {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("{subject} changed while being read"),
        ));
    }
    Ok(content)
}

fn size_limit_exceeded(subject: &str) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        format!("{subject} exceeds its size limit"),
    )
}

pub(super) fn regular_file_length(path: &Path, subject: &str) -> io::Result<u64> {
    let file = OpenOptions::new()
        .read(true)
        .share_mode(FILE_SHARE_READ | FILE_SHARE_DELETE)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || is_reparse(&metadata) {
        return Err(unsafe_path(subject, path));
    }
    Ok(metadata.len())
}

fn is_reparse(metadata: &fs::Metadata) -> bool {
    metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

fn unsafe_path(subject: &str, path: &Path) -> io::Error {
    io::Error::other(format!(
        "{subject} must be a regular filesystem entry: {}",
        path.display()
    ))
}

fn is_lock_contention(error: &io::Error) -> bool {
    matches!(
        error.raw_os_error(),
        Some(code) if code == ERROR_SHARING_VIOLATION as i32 || code == ERROR_LOCK_VIOLATION as i32
    )
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicU64, Ordering};

    use super::*;

    static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

    struct Fixture {
        root: PathBuf,
    }

    impl Fixture {
        fn new() -> Self {
            let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
            let root = std::env::temp_dir().join(format!(
                "swawkit-proj-dev-storage-{}-{sequence}",
                std::process::id()
            ));
            fs::create_dir_all(&root).expect("create storage fixture");
            Self { root }
        }

        fn file(&self, name: &str, content: &[u8]) -> PathBuf {
            let path = self.root.join(name);
            fs::write(&path, content).expect("write storage fixture");
            path
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    fn read_with_length_change(
        path: &Path,
        maximum: u64,
        changed_length: u64,
    ) -> io::Result<Vec<u8>> {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .share_mode(FILE_SHARE_READ | FILE_SHARE_DELETE)
            .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
            .open(path)?;
        read_replaceable_bounded_from_file(file, path, "Dev Settings", maximum, |file| {
            file.set_len(changed_length)
        })
    }

    #[test]
    fn rejects_a_file_that_grows_within_the_bound_after_initial_metadata() {
        let fixture = Fixture::new();
        let path = fixture.file("growing.json", b"{}");

        let error = read_with_length_change(&path, 16, 3).unwrap_err();

        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert_eq!(error.to_string(), "Dev Settings changed while being read");
    }

    #[test]
    fn bounded_reader_rejects_growth_beyond_the_limit() {
        let fixture = Fixture::new();
        let path = fixture.file("oversized-growth.json", b"{}");

        let error = read_with_length_change(&path, 16, 17).unwrap_err();

        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert_eq!(error.to_string(), "Dev Settings exceeds its size limit");
    }

    #[test]
    fn rejects_a_file_that_is_truncated_after_initial_metadata() {
        let fixture = Fixture::new();
        let path = fixture.file("truncated.json", b"{}\n");

        let error = read_with_length_change(&path, 16, 2).unwrap_err();

        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert_eq!(error.to_string(), "Dev Settings changed while being read");
    }
}
