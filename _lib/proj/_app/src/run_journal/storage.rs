use std::fs::{self, Metadata, OpenOptions};
use std::io::{self, Read};
use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;

use serde::{Deserialize, Serialize};
use windows_sys::Win32::Storage::FileSystem::{
    FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_OPEN_REPARSE_POINT,
};

use crate::atomic_file;

use super::{JOURNAL_STATE_SCHEMA, RunJournalEvent, RunJournalSource, RunJournalStatus};

pub(super) const MAX_STATE_BYTES: u64 = 64 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct StoredRunState {
    pub schema: String,
    pub id: String,
    pub address: String,
    pub source: RunJournalSource,
    pub status: RunJournalStatus,
    pub started_at_unix_ms: u64,
    pub finished_at_unix_ms: Option<u64>,
    pub exit_code: Option<i32>,
    pub error: Option<String>,
    pub argument_count: usize,
    pub event_count: u64,
    pub truncated: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct LegacyStoredRunState {
    #[serde(rename = "schema")]
    pub _schema: String,
    pub id: String,
    pub address: String,
    pub source: RunJournalSource,
    pub status: RunJournalStatus,
    pub started_at_unix_ms: u64,
    pub finished_at_unix_ms: Option<u64>,
    pub exit_code: Option<i32>,
    pub error: Option<String>,
    pub argument_count: usize,
    pub profile_revision: String,
    pub event_count: u64,
    pub truncated: bool,
}

impl From<LegacyStoredRunState> for StoredRunState {
    fn from(state: LegacyStoredRunState) -> Self {
        Self {
            schema: JOURNAL_STATE_SCHEMA.to_owned(),
            id: state.id,
            address: state.address,
            source: state.source,
            status: state.status,
            started_at_unix_ms: state.started_at_unix_ms,
            finished_at_unix_ms: state.finished_at_unix_ms,
            exit_code: state.exit_code,
            error: state.error,
            argument_count: state.argument_count,
            event_count: state.event_count,
            truncated: state.truncated,
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct StoredRunEvent {
    pub schema: String,
    pub run_id: String,
    #[serde(flatten)]
    pub event: RunJournalEvent,
}

pub(super) fn publish_stored_state(path: &Path, state: &StoredRunState) -> io::Result<()> {
    let mut content = serde_json::to_vec_pretty(state).map_err(io::Error::other)?;
    content.push(b'\n');
    atomic_file::publish(path, &content)
}

pub(super) fn assert_plain_directory(path: &Path) -> io::Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_dir() || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(io::Error::other(format!(
            "run journal directory must be a normal directory: {}",
            path.display()
        )));
    }
    Ok(())
}

pub(super) fn assert_plain_file(path: &Path) -> io::Result<()> {
    plain_file_metadata(path).map(|_| ())
}

pub(super) fn read_stored_state(path: &Path) -> io::Result<Vec<u8>> {
    read_stored_state_inner(path, |_| Ok(()))
}

#[cfg(test)]
pub(super) fn read_stored_state_with_before_read(
    path: &Path,
    before_read: impl FnOnce(&Path) -> io::Result<()>,
) -> io::Result<Vec<u8>> {
    read_stored_state_inner(path, before_read)
}

fn read_stored_state_inner(
    path: &Path,
    before_read: impl FnOnce(&Path) -> io::Result<()>,
) -> io::Result<Vec<u8>> {
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)?;
    let metadata = file.metadata()?;
    assert_plain_file_metadata(path, &metadata)?;
    if metadata.len() > MAX_STATE_BYTES {
        return Err(state_too_large());
    }

    let initial_length = metadata.len();
    before_read(path)?;
    let mut content = Vec::with_capacity(initial_length as usize);
    file.by_ref()
        .take(MAX_STATE_BYTES + 1)
        .read_to_end(&mut content)?;
    if content.len() as u64 > MAX_STATE_BYTES {
        return Err(state_too_large());
    }
    let final_metadata = file.metadata()?;
    assert_plain_file_metadata(path, &final_metadata)?;
    if final_metadata.len() > MAX_STATE_BYTES {
        return Err(state_too_large());
    }
    if final_metadata.len() != initial_length || content.len() as u64 != initial_length {
        return Err(state_changed());
    }
    Ok(content)
}

fn plain_file_metadata(path: &Path) -> io::Result<Metadata> {
    let metadata = fs::symlink_metadata(path)?;
    assert_plain_file_metadata(path, &metadata)?;
    Ok(metadata)
}

fn assert_plain_file_metadata(path: &Path, metadata: &Metadata) -> io::Result<()> {
    if !metadata.is_file() || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(io::Error::other(format!(
            "run journal file must be a normal file: {}",
            path.display()
        )));
    }
    Ok(())
}

fn state_too_large() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        "run journal state file exceeds its storage contract",
    )
}

fn state_changed() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        "run journal state file changed while being read",
    )
}

pub(super) fn ensure_plain_directory(path: &Path) -> io::Result<()> {
    fs::create_dir_all(path)?;
    assert_plain_directory(path)
}

pub(super) fn new_running_state(
    id: &str,
    address: String,
    source: RunJournalSource,
    started_at_unix_ms: u64,
    argument_count: usize,
) -> StoredRunState {
    StoredRunState {
        schema: JOURNAL_STATE_SCHEMA.to_owned(),
        id: id.to_owned(),
        address,
        source,
        status: RunJournalStatus::Running,
        started_at_unix_ms,
        finished_at_unix_ms: None,
        exit_code: None,
        error: None,
        argument_count,
        event_count: 0,
        truncated: false,
    }
}
