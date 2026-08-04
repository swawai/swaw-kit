use std::error::Error;
use std::fmt;
use std::fs;
use std::os::windows::fs::MetadataExt;
use std::path::{Path, PathBuf};

use windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT;

use super::record::{EntryRecordState, read_entry_record};

#[derive(Debug, Clone)]
pub struct DataRootInventory {
    directory: PathBuf,
    roots: Vec<DataRootSnapshot>,
}

impl DataRootInventory {
    pub fn scan(directory: &Path) -> Result<Self, DataRootInventoryError> {
        let directory = std::path::absolute(directory).map_err(|error| {
            DataRootInventoryError::new(format!(
                "invalid project data directory '{}': {error}",
                directory.display()
            ))
        })?;
        if !directory.exists() {
            return Ok(Self {
                directory,
                roots: Vec::new(),
            });
        }
        reject_reparse_point(&directory, "project data directory")?;
        if !directory.is_dir() {
            return Err(DataRootInventoryError::new(format!(
                "project data directory is not a directory: {}",
                directory.display()
            )));
        }

        let mut roots = Vec::new();
        let entries = fs::read_dir(&directory).map_err(|error| {
            DataRootInventoryError::new(format!(
                "cannot enumerate project data directory '{}': {error}",
                directory.display()
            ))
        })?;
        for entry in entries {
            let entry = entry.map_err(|error| {
                DataRootInventoryError::new(format!(
                    "cannot enumerate project data directory '{}': {error}",
                    directory.display()
                ))
            })?;
            let name = entry.file_name();
            if !name.to_string_lossy().to_ascii_lowercase().starts_with("proj.") {
                continue;
            }
            let path = entry.path();
            let metadata = fs::symlink_metadata(&path).map_err(|error| {
                DataRootInventoryError::new(format!(
                    "cannot inspect project DataRoot '{}': {error}",
                    path.display()
                ))
            })?;
            if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
                return Err(DataRootInventoryError::new(format!(
                    "project DataRoot cannot be a reparse point: {}",
                    path.display()
                )));
            }
            if !metadata.is_dir() {
                continue;
            }
            roots.push(DataRootSnapshot {
                record: read_entry_record(&path),
                path,
            });
        }
        roots.sort_by(|left, right| left.path.cmp(&right.path));
        Ok(Self { directory, roots })
    }

    pub fn directory(&self) -> &Path {
        &self.directory
    }

    pub(crate) fn roots(&self) -> &[DataRootSnapshot] {
        &self.roots
    }

    #[cfg(test)]
    pub(crate) fn from_snapshots(
        directory: PathBuf,
        snapshots: Vec<(PathBuf, EntryRecordState)>,
    ) -> Self {
        Self {
            directory,
            roots: snapshots
                .into_iter()
                .map(|(path, record)| DataRootSnapshot { path, record })
                .collect(),
        }
    }
}

#[derive(Debug, Clone)]
pub(crate) struct DataRootSnapshot {
    pub(crate) path: PathBuf,
    pub(crate) record: EntryRecordState,
}

fn reject_reparse_point(path: &Path, label: &str) -> Result<(), DataRootInventoryError> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        DataRootInventoryError::new(format!("cannot inspect {label} '{}': {error}", path.display()))
    })?;
    if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(DataRootInventoryError::new(format!(
            "{label} cannot be a reparse point: {}",
            path.display()
        )));
    }
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DataRootInventoryError {
    message: String,
}

impl DataRootInventoryError {
    fn new(message: String) -> Self {
        Self { message }
    }
}

impl fmt::Display for DataRootInventoryError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl Error for DataRootInventoryError {}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

    #[test]
    fn scans_only_project_directories_and_preserves_invalid_records() {
        let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "swawkit-data-inventory-{}-{sequence}",
            std::process::id()
        ));
        fs::create_dir_all(root.join("proj.valid")).expect("create valid root");
        fs::create_dir(root.join("PROJ.invalid")).expect("create invalid root");
        fs::create_dir(root.join("cache")).expect("create unrelated directory");
        fs::write(root.join("proj.file"), "not a directory").expect("write unrelated file");
        fs::write(root.join("PROJ.invalid/_entry.json"), "not json")
            .expect("write invalid record");

        let inventory = DataRootInventory::scan(&root).expect("scan inventory");
        assert_eq!(inventory.roots.len(), 2);
        assert!(inventory.roots.iter().any(|root| matches!(
            root.record,
            EntryRecordState::Missing { .. }
        )));
        assert!(inventory.roots.iter().any(|root| matches!(
            root.record,
            EntryRecordState::Invalid { .. }
        )));

        fs::remove_dir_all(root).expect("remove fixture");
    }
}
