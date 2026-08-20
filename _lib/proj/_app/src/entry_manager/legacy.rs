use std::fs::{self, OpenOptions};
use std::io::Read;
use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;

use serde::Deserialize;
use windows_sys::Win32::Storage::FileSystem::{
    FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_READ,
};

const LEGACY_RECORD_FILE: &str = "_entry.json";
const LEGACY_RECORD_SCHEMA: &str = "swawkit.proj-entry.v0";
const MAX_LEGACY_RECORD_BYTES: u64 = 64 * 1024;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LegacyEntryRecord {
    schema: String,
    entry_name: String,
    entry_file: Option<String>,
    volume_id: String,
    file_id: String,
}

pub(super) fn validate_legacy_record(data_root: &Path, name: &str) -> Result<(), String> {
    let path = data_root.join(LEGACY_RECORD_FILE);
    let mut file = OpenOptions::new()
        .read(true)
        .share_mode(FILE_SHARE_READ)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(&path)
        .map_err(|error| format!("legacy Entry record is missing or unreadable: {error}"))?;
    let metadata = file
        .metadata()
        .map_err(|error| format!("cannot inspect legacy Entry record: {error}"))?;
    if !metadata.is_file()
        || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
        || metadata.len() == 0
        || metadata.len() > MAX_LEGACY_RECORD_BYTES
    {
        return Err("legacy Entry record must be a bounded regular non-reparse file".to_owned());
    }
    let mut content = Vec::with_capacity(metadata.len() as usize);
    (&mut file)
        .take(MAX_LEGACY_RECORD_BYTES + 1)
        .read_to_end(&mut content)
        .map_err(|error| format!("cannot read legacy Entry record: {error}"))?;
    if content.len() as u64 != metadata.len()
        || file.metadata().map(|m| m.len()).ok() != Some(metadata.len())
    {
        return Err("legacy Entry record changed while it was read".to_owned());
    }
    let record: LegacyEntryRecord = serde_json::from_slice(&content)
        .map_err(|error| format!("legacy Entry record is invalid: {error}"))?;
    let expected_file = format!("{name}.exe");
    if record.schema != LEGACY_RECORD_SCHEMA
        || record.entry_name != name
        || record.entry_file.as_deref() != Some(expected_file.as_str())
        || !valid_volume_id(&record.volume_id)
        || !valid_file_id(&record.file_id)
    {
        return Err("legacy Entry record does not exactly identify the requested Entry".to_owned());
    }
    Ok(())
}

fn valid_volume_id(value: &str) -> bool {
    let lowercase = value.to_ascii_lowercase();
    let Some(body) = lowercase
        .strip_prefix(r"\\?\volume{")
        .and_then(|value| value.strip_suffix('}'))
    else {
        return false;
    };
    !body.is_empty()
        && body
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() || byte == b'-')
}

fn valid_file_id(value: &str) -> bool {
    (16..=32).contains(&value.len())
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

pub(super) fn legacy_record_exists(data_root: &Path) -> bool {
    fs::symlink_metadata(data_root.join(LEGACY_RECORD_FILE)).is_ok()
}
