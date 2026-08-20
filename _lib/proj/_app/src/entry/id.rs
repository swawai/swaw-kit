use std::error::Error;
use std::ffi::OsStr;
use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::windows::ffi::OsStrExt;
use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

use windows_sys::Win32::Storage::FileSystem::{
    FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_READ,
    MOVEFILE_WRITE_THROUGH, MoveFileExW,
};
use windows_sys::Win32::System::Com::CoCreateGuid;
use windows_sys::core::GUID;

pub const ENTRY_ID_FILE_NAME: &str = "entry.id";
const ENTRY_ID_LENGTH: usize = 64;
const ENTRY_ID_DOCUMENT_LENGTH: u64 = 65;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct EntryId(String);

impl EntryId {
    pub fn parse(value: &str) -> Result<Self, EntryIdError> {
        if value.len() != ENTRY_ID_LENGTH
            || !value
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return Err(EntryIdError::invalid(
                "Entry ID must contain exactly 64 lowercase hexadecimal bytes",
            ));
        }
        Ok(Self(value.to_owned()))
    }

    pub fn read(data_root: &Path) -> Result<Self, EntryIdError> {
        let (_file, id) = open_entry_id(data_root)?;
        Ok(id)
    }

    /// Creates the immutable identity of an explicitly initialized or migrated
    /// Entry. Ordinary command execution must only call [`Self::read`].
    pub fn create_once(data_root: &Path) -> Result<Self, EntryIdError> {
        validate_data_root(data_root)?;
        let id = fresh_id()?;
        let path = data_root.join(ENTRY_ID_FILE_NAME);
        let temporary = data_root.join(format!(".entry.id.{}.tmp", id.as_str()));
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
            .open(&temporary)
            .map_err(|error| io_error("create staged Entry ID", &temporary, error))?;
        let content = format!("{}\n", id.as_str());
        if let Err(error) = file
            .write_all(content.as_bytes())
            .and_then(|()| file.sync_all())
        {
            drop(file);
            let _ = fs::remove_file(&temporary);
            return Err(io_error("write staged Entry ID", &temporary, error));
        }
        drop(file);
        if let Err(error) = move_create_new(&temporary, &path) {
            let _ = fs::remove_file(&temporary);
            return if fs::symlink_metadata(&path).is_ok() {
                Err(EntryIdError::new(
                    EntryIdErrorKind::AlreadyExists,
                    format!("Entry ID already exists: {}", path.display()),
                ))
            } else {
                Err(io_error("publish Entry ID", &path, error))
            };
        }
        Ok(id)
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub(crate) fn open_pinned(data_root: &Path) -> Result<(File, Self), EntryIdError> {
        open_entry_id(data_root)
    }
}

fn move_create_new(source: &Path, target: &Path) -> std::io::Result<()> {
    let source = canonical_sibling(source)?;
    let target = canonical_sibling(target)?;
    let source = null_terminated(source.as_os_str());
    let target = null_terminated(target.as_os_str());
    let result = unsafe { MoveFileExW(source.as_ptr(), target.as_ptr(), MOVEFILE_WRITE_THROUGH) };
    if result == 0 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(())
    }
}

fn canonical_sibling(path: &Path) -> std::io::Result<PathBuf> {
    let parent = path.parent().ok_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "Entry ID path has no parent",
        )
    })?;
    let name = path.file_name().ok_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "Entry ID path has no file name",
        )
    })?;
    Ok(fs::canonicalize(parent)?.join(name))
}

fn null_terminated(value: &OsStr) -> Vec<u16> {
    value.encode_wide().chain(std::iter::once(0)).collect()
}

impl fmt::Display for EntryId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

fn open_entry_id(data_root: &Path) -> Result<(File, EntryId), EntryIdError> {
    let path = data_root.join(ENTRY_ID_FILE_NAME);
    let file = OpenOptions::new()
        .read(true)
        .share_mode(FILE_SHARE_READ)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(&path)
        .map_err(|error| {
            if error.kind() == std::io::ErrorKind::NotFound {
                EntryIdError::new(
                    EntryIdErrorKind::Missing,
                    format!("Entry ID is missing: {}", path.display()),
                )
            } else {
                io_error("open Entry ID", &path, error)
            }
        })?;
    let metadata = file
        .metadata()
        .map_err(|error| io_error("inspect Entry ID", &path, error))?;
    if !metadata.is_file() || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(EntryIdError::invalid(format!(
            "Entry ID must be a regular non-reparse file: {}",
            path.display()
        )));
    }
    if metadata.len() != ENTRY_ID_DOCUMENT_LENGTH {
        return Err(EntryIdError::invalid(format!(
            "Entry ID document must contain exactly 64 lowercase hexadecimal bytes and a newline: {}",
            path.display()
        )));
    }
    let mut content = Vec::with_capacity(ENTRY_ID_DOCUMENT_LENGTH as usize);
    (&file)
        .take(ENTRY_ID_DOCUMENT_LENGTH + 1)
        .read_to_end(&mut content)
        .map_err(|error| io_error("read Entry ID", &path, error))?;
    let value = content.strip_suffix(b"\n").ok_or_else(|| {
        EntryIdError::invalid(format!(
            "Entry ID document must end with one newline: {}",
            path.display()
        ))
    })?;
    let value = std::str::from_utf8(value).map_err(|_| {
        EntryIdError::invalid(format!("Entry ID is not valid UTF-8: {}", path.display()))
    })?;
    let id = EntryId::parse(value).map_err(|error| {
        EntryIdError::invalid(format!("invalid Entry ID '{}': {error}", path.display()))
    })?;
    Ok((file, id))
}

fn validate_data_root(data_root: &Path) -> Result<(), EntryIdError> {
    let metadata = fs::symlink_metadata(data_root)
        .map_err(|error| io_error("inspect Entry DataRoot", data_root, error))?;
    if !metadata.is_dir() || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(EntryIdError::invalid(format!(
            "Entry DataRoot must be a regular non-reparse directory: {}",
            data_root.display()
        )));
    }
    Ok(())
}

fn fresh_id() -> Result<EntryId, EntryIdError> {
    let first = fresh_token()?;
    let second = fresh_token()?;
    EntryId::parse(&format!("{first}{second}"))
}

fn fresh_token() -> Result<String, EntryIdError> {
    let mut guid = GUID::default();
    // SAFETY: `guid` is writable storage for one GUID and outlives this call.
    let result = unsafe { CoCreateGuid(&mut guid) };
    if result < 0 {
        return Err(EntryIdError::new(
            EntryIdErrorKind::Io,
            format!("cannot generate Entry ID: HRESULT 0x{:08x}", result as u32),
        ));
    }
    Ok(format!(
        "{:08x}{:04x}{:04x}{}",
        guid.data1,
        guid.data2,
        guid.data3,
        guid.data4
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>()
    ))
}

fn io_error(action: &str, path: &Path, error: std::io::Error) -> EntryIdError {
    EntryIdError::new(
        EntryIdErrorKind::Io,
        format!("cannot {action} '{}': {error}", path.display()),
    )
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EntryIdErrorKind {
    Missing,
    AlreadyExists,
    Invalid,
    Io,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EntryIdError {
    kind: EntryIdErrorKind,
    message: String,
}

impl EntryIdError {
    fn new(kind: EntryIdErrorKind, message: String) -> Self {
        Self { kind, message }
    }

    fn invalid(message: impl Into<String>) -> Self {
        Self::new(EntryIdErrorKind::Invalid, message.into())
    }

    pub fn kind(&self) -> EntryIdErrorKind {
        self.kind
    }
}

impl fmt::Display for EntryIdError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl Error for EntryIdError {}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::{Arc, Barrier};

    static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

    struct Fixture(PathBuf);

    impl Fixture {
        fn new() -> Self {
            let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
            let root = std::env::temp_dir().join(format!(
                "swawkit-entry-id-{}-{sequence}",
                std::process::id()
            ));
            fs::create_dir(&root).expect("create Entry ID fixture");
            Self(root)
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn creates_reads_and_never_replaces_an_entry_id() {
        let fixture = Fixture::new();
        let created = EntryId::create_once(&fixture.0).expect("create Entry ID");
        assert_eq!(created.as_str().len(), 64);
        assert_eq!(EntryId::read(&fixture.0).unwrap(), created);
        assert_eq!(
            EntryId::create_once(&fixture.0).unwrap_err().kind(),
            EntryIdErrorKind::AlreadyExists
        );
        assert_eq!(
            fs::read(fixture.0.join(ENTRY_ID_FILE_NAME)).unwrap(),
            format!("{created}\n").as_bytes()
        );
    }

    #[test]
    fn rejects_noncanonical_documents() {
        let fixture = Fixture::new();
        for content in [
            "a".repeat(64),
            format!("{}\r\n", "a".repeat(64)),
            format!("{}\n", "A".repeat(64)),
            format!("{}g\n", "a".repeat(63)),
        ] {
            fs::write(fixture.0.join(ENTRY_ID_FILE_NAME), content).unwrap();
            assert_eq!(
                EntryId::read(&fixture.0).unwrap_err().kind(),
                EntryIdErrorKind::Invalid
            );
        }
    }

    #[test]
    fn concurrent_create_once_has_one_complete_winner_and_no_partial_document() {
        let fixture = Fixture::new();
        let root = Arc::new(fixture.0.clone());
        let barrier = Arc::new(Barrier::new(9));
        let workers = (0..8)
            .map(|_| {
                let root = Arc::clone(&root);
                let barrier = Arc::clone(&barrier);
                std::thread::spawn(move || {
                    barrier.wait();
                    EntryId::create_once(&root)
                })
            })
            .collect::<Vec<_>>();
        barrier.wait();
        let results = workers
            .into_iter()
            .map(|worker| worker.join().unwrap())
            .collect::<Vec<_>>();

        assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
        assert!(
            results
                .iter()
                .filter_map(|result| result.as_ref().err())
                .all(|error| { error.kind() == EntryIdErrorKind::AlreadyExists })
        );
        EntryId::read(&fixture.0).expect("read the one complete winner");
        assert!(fs::read_dir(&fixture.0).unwrap().all(|item| {
            !item
                .unwrap()
                .file_name()
                .to_string_lossy()
                .ends_with(".tmp")
        }));
    }
}
