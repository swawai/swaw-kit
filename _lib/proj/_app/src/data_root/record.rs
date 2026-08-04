use std::error::Error;
use std::ffi::OsStr;
use std::fmt;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use windows_sys::Win32::Storage::FileSystem::{
    FILE_ATTRIBUTE_REPARSE_POINT, REPLACEFILE_IGNORE_MERGE_ERRORS,
    REPLACEFILE_WRITE_THROUGH, ReplaceFileW,
};

use crate::entry::{EntryIdentity, is_valid_file_id, is_valid_volume_id};

pub const ENTRY_RECORD_SCHEMA: &str = "swawkit.proj-entry.v0";
static NEXT_PUBLICATION: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EntryRecord {
    pub schema: String,
    pub entry_name: String,
    pub entry_file: Option<String>,
    pub volume_id: String,
    pub file_id: String,
}

impl EntryRecord {
    pub fn matches_identity(&self, identity: &EntryIdentity) -> bool {
        self.volume_id == identity.volume_id() && self.file_id == identity.file_id()
    }

    fn validate(&self) -> Result<(), String> {
        for (name, value) in [
            ("schema", self.schema.as_str()),
            ("entryName", self.entry_name.as_str()),
            ("volumeId", self.volume_id.as_str()),
            ("fileId", self.file_id.as_str()),
        ] {
            if value.trim().is_empty() {
                return Err(format!("required property '{name}' is missing"));
            }
        }
        if self.schema != ENTRY_RECORD_SCHEMA {
            return Err(format!("unsupported schema '{}'", self.schema));
        }
        if !is_valid_volume_id(&self.volume_id) {
            return Err("volumeId is invalid".to_owned());
        }
        if !is_valid_file_id(&self.file_id) {
            return Err("fileId is invalid".to_owned());
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EntryRecordState {
    Missing { path: PathBuf },
    Invalid { path: PathBuf, error: String },
    Valid { path: PathBuf, record: EntryRecord },
}

impl EntryRecordState {
    pub fn valid_record(&self) -> Option<&EntryRecord> {
        match self {
            Self::Valid { record, .. } => Some(record),
            Self::Missing { .. } | Self::Invalid { .. } => None,
        }
    }

    pub fn invalid_reason(&self) -> Option<&str> {
        match self {
            Self::Missing { .. } => Some("identity record is missing"),
            Self::Invalid { error, .. } => Some(error),
            Self::Valid { .. } => None,
        }
    }
}

pub fn read_entry_record(data_root: &Path) -> EntryRecordState {
    let path = data_root.join("_entry.json");
    if !path.is_file() {
        return EntryRecordState::Missing { path };
    }
    let result = fs::read_to_string(&path)
        .map_err(|error| error.to_string())
        .and_then(|content| {
            serde_json::from_str::<EntryRecord>(&content).map_err(|error| error.to_string())
        })
        .and_then(|record| {
            record.validate()?;
            Ok(record)
        });
    match result {
        Ok(record) => EntryRecordState::Valid { path, record },
        Err(error) => EntryRecordState::Invalid { path, error },
    }
}

pub(crate) fn publish_entry_record(
    data_root: &Path,
    entry_name: &str,
    entry_file: &Path,
    identity: &EntryIdentity,
) -> Result<(), EntryRecordWriteError> {
    let data_root_metadata = fs::symlink_metadata(data_root).map_err(|error| {
        EntryRecordWriteError::new(format!(
            "cannot inspect DataRoot '{}': {error}",
            data_root.display()
        ))
    })?;
    if data_root_metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(EntryRecordWriteError::new(format!(
            "project DataRoot cannot be a reparse point: {}",
            data_root.display()
        )));
    }
    if !data_root_metadata.is_dir() {
        return Err(EntryRecordWriteError::new(format!(
            "cannot publish identity for a missing DataRoot: {}",
            data_root.display()
        )));
    }
    let entry_file_name = entry_file
        .file_name()
        .and_then(OsStr::to_str)
        .ok_or_else(|| {
            EntryRecordWriteError::new(format!(
                "project entry file has no usable Unicode name: {}",
                entry_file.display()
            ))
        })?;
    let record = EntryRecord {
        schema: ENTRY_RECORD_SCHEMA.to_owned(),
        entry_name: entry_name.to_owned(),
        entry_file: Some(entry_file_name.to_owned()),
        volume_id: identity.volume_id().to_owned(),
        file_id: identity.file_id().to_owned(),
    };
    let mut content = serde_json::to_string_pretty(&record).map_err(|error| {
        EntryRecordWriteError::new(format!("cannot serialize project entry identity: {error}"))
    })?;
    content.push('\n');

    let record_path = data_root.join("_entry.json");
    let temporary_path = unique_sibling(data_root, "._entry", "tmp");
    let backup_path = unique_sibling(data_root, "._entry", "backup");
    let result = publish_atomic(
        &record_path,
        &temporary_path,
        &backup_path,
        content.as_bytes(),
    );
    for path in [&temporary_path, &backup_path] {
        if path.exists() {
            fs::remove_file(path).map_err(|error| {
                EntryRecordWriteError::new(format!(
                    "cannot clean identity publication '{}': {error}",
                    path.display()
                ))
            })?;
        }
    }
    result
}

fn publish_atomic(
    record_path: &Path,
    temporary_path: &Path,
    backup_path: &Path,
    content: &[u8],
) -> Result<(), EntryRecordWriteError> {
    let mut temporary = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(temporary_path)
        .map_err(|error| publication_error("create", temporary_path, error))?;
    temporary
        .write_all(content)
        .and_then(|_| temporary.sync_all())
        .map_err(|error| publication_error("write", temporary_path, error))?;
    drop(temporary);

    if !record_path.exists() {
        return fs::rename(temporary_path, record_path)
            .map_err(|error| publication_error("publish", record_path, error));
    }
    replace_file(record_path, temporary_path, backup_path)
}

fn replace_file(
    record_path: &Path,
    temporary_path: &Path,
    backup_path: &Path,
) -> Result<(), EntryRecordWriteError> {
    let record = null_terminated(record_path.as_os_str());
    let temporary = null_terminated(temporary_path.as_os_str());
    let backup = null_terminated(backup_path.as_os_str());
    let succeeded = unsafe {
        ReplaceFileW(
            record.as_ptr(),
            temporary.as_ptr(),
            backup.as_ptr(),
            REPLACEFILE_IGNORE_MERGE_ERRORS | REPLACEFILE_WRITE_THROUGH,
            std::ptr::null(),
            std::ptr::null(),
        )
    };
    if succeeded == 0 {
        return Err(publication_error(
            "replace",
            record_path,
            std::io::Error::last_os_error(),
        ));
    }
    Ok(())
}

fn unique_sibling(directory: &Path, prefix: &str, suffix: &str) -> PathBuf {
    let sequence = NEXT_PUBLICATION.fetch_add(1, Ordering::Relaxed);
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    directory.join(format!(
        "{prefix}.{}.{timestamp}.{sequence}.{suffix}",
        std::process::id()
    ))
}

fn null_terminated(value: &OsStr) -> Vec<u16> {
    value.encode_wide().chain(std::iter::once(0)).collect()
}

fn publication_error(action: &str, path: &Path, error: std::io::Error) -> EntryRecordWriteError {
    EntryRecordWriteError::new(format!(
        "cannot {action} project entry identity '{}': {error}",
        path.display()
    ))
}

#[derive(Debug)]
pub(crate) struct EntryRecordWriteError {
    message: String,
}

impl EntryRecordWriteError {
    fn new(message: String) -> Self {
        Self { message }
    }
}

impl fmt::Display for EntryRecordWriteError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl Error for EntryRecordWriteError {}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

    struct Fixture(PathBuf);

    impl Fixture {
        fn new() -> Self {
            let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "swawkit-entry-record-{}-{sequence}",
                std::process::id()
            ));
            fs::create_dir(&path).expect("create fixture");
            Self(path)
        }

        fn write(&self, content: &str) {
            fs::write(self.0.join("_entry.json"), content).expect("write identity record");
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn distinguishes_missing_invalid_and_valid_records() {
        let fixture = Fixture::new();
        assert!(matches!(
            read_entry_record(&fixture.0),
            EntryRecordState::Missing { .. }
        ));

        fixture.write(r#"{"schema":"wrong"}"#);
        assert!(matches!(
            read_entry_record(&fixture.0),
            EntryRecordState::Invalid { .. }
        ));

        fixture.write(
            r#"{
                "schema":"swawkit.proj-entry.v0",
                "entryName":"project-one",
                "entryFile":"project-one.exe",
                "volumeId":"\\\\?\\volume{91cf565a-694f-4232-be2d-368578d28629}",
                "fileId":"0000000000000000001400000000685d"
            }"#,
        );
        assert!(matches!(
            read_entry_record(&fixture.0),
            EntryRecordState::Valid { .. }
        ));
    }

    #[test]
    fn keeps_case_significant_for_persisted_identity_matching() {
        let identity = EntryIdentity::from_parts(
            r"\\?\volume{91cf565a-694f-4232-be2d-368578d28629}",
            "0000000000000000001400000000685d",
        )
        .expect("identity");
        let record = EntryRecord {
            schema: ENTRY_RECORD_SCHEMA.to_owned(),
            entry_name: "project-one".to_owned(),
            entry_file: None,
            volume_id: identity.volume_id().to_uppercase(),
            file_id: identity.file_id().to_owned(),
        };
        assert!(!record.matches_identity(&identity));
    }
}
