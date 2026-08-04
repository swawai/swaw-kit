use std::fs;
use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::entry::{EntryIdentity, is_valid_file_id, is_valid_volume_id};

pub const ENTRY_RECORD_SCHEMA: &str = "swawkit.proj-entry.v0";

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
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
