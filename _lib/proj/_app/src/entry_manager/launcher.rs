use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use windows_sys::Win32::Storage::FileSystem::{
    FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_READ,
};

use crate::atomic_file;

use super::EntryManagerError;

const LAUNCHER_RECEIPT_FILE: &str = "launcher.json";
const LAUNCHER_RECEIPT_SCHEMA: &str = "swawkit.entry-launcher/v1";
const MAX_LAUNCHER_BYTES: u64 = 16 * 1024 * 1024;
const MAX_RECEIPT_BYTES: u64 = 16 * 1024;
static NEXT_STAGE: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Clone)]
pub(super) struct LauncherArtifact {
    bytes: Vec<u8>,
    length: u64,
    sha256: String,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LauncherReceipt {
    schema: String,
    entry_name: String,
    length: u64,
    sha256: String,
}

impl LauncherArtifact {
    pub fn read(path: &Path) -> Result<Self, EntryManagerError> {
        let (bytes, length) = read_regular(path, "manager Launcher", MAX_LAUNCHER_BYTES)
            .map_err(|error| EntryManagerError::io("read the manager Launcher", error))?;
        Ok(Self {
            sha256: format!("{:x}", Sha256::digest(&bytes)),
            bytes,
            length,
        })
    }

    pub fn publish_receipt_create(
        &self,
        data_root: &Path,
        entry_name: &str,
    ) -> Result<(), EntryManagerError> {
        let content = self.receipt_content(entry_name)?;
        write_new_synced(&data_root.join(LAUNCHER_RECEIPT_FILE), &content)
            .map_err(|error| EntryManagerError::io("create the Launcher receipt", error))
    }

    pub fn publish_receipt_replace(
        &self,
        data_root: &Path,
        entry_name: &str,
    ) -> Result<(), EntryManagerError> {
        let content = self.receipt_content(entry_name)?;
        atomic_file::publish(&data_root.join(LAUNCHER_RECEIPT_FILE), &content)
            .map_err(|error| EntryManagerError::io("replace the Launcher receipt", error))
    }

    fn receipt_content(&self, entry_name: &str) -> Result<Vec<u8>, EntryManagerError> {
        let content = serde_json::to_vec_pretty(&LauncherReceipt {
            schema: LAUNCHER_RECEIPT_SCHEMA.to_owned(),
            entry_name: entry_name.to_owned(),
            length: self.length,
            sha256: self.sha256.clone(),
        })
        .map_err(|error| {
            EntryManagerError::corrupt(format!("cannot serialize Launcher receipt: {error}"))
        })?;
        let mut content = content;
        content.push(b'\n');
        Ok(content)
    }

    pub fn install_create(&self, target: &Path) -> Result<(), EntryManagerError> {
        let stage = unique_stage(target)?;
        let result = (|| {
            write_new_synced(&stage, &self.bytes)?;
            verify_bytes(&stage, self)?;
            fs::rename(&stage, target)?;
            verify_bytes(target, self)
        })();
        if result.is_err() {
            let _ = fs::remove_file(&stage);
        }
        result.map_err(|error| EntryManagerError::io("install the Entry Launcher", error))
    }

    pub fn install_replace(&self, target: &Path) -> Result<(), EntryManagerError> {
        if let Ok(metadata) = fs::symlink_metadata(target)
            && (!metadata.is_file()
                || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0)
        {
            return Err(EntryManagerError::conflict(format!(
                "Entry Launcher is not a regular non-reparse file: {}",
                target.display()
            )));
        }
        atomic_file::publish(target, &self.bytes)
            .map_err(|error| EntryManagerError::io("replace the legacy Entry Launcher", error))?;
        verify_bytes(target, self)
            .map_err(|error| EntryManagerError::io("verify the installed Entry Launcher", error))
    }
}

pub(super) fn validate_installed(
    data_root: &Path,
    launcher: &Path,
    entry_name: &str,
) -> Result<(), String> {
    let receipt = read_receipt(data_root, entry_name)?;
    let (bytes, length) = read_regular(launcher, "Entry Launcher", MAX_LAUNCHER_BYTES)
        .map_err(|error| format!("Entry Launcher is missing or invalid: {error}"))?;
    if length != receipt.length || format!("{:x}", Sha256::digest(&bytes)) != receipt.sha256 {
        return Err("Entry Launcher does not match its immutable receipt".to_owned());
    }
    Ok(())
}

pub(super) fn validate_receipt(data_root: &Path, entry_name: &str) -> Result<(), String> {
    read_receipt(data_root, entry_name).map(|_| ())
}

pub(super) fn receipt_exists(data_root: &Path) -> bool {
    fs::symlink_metadata(data_root.join(LAUNCHER_RECEIPT_FILE)).is_ok()
}

fn read_receipt(data_root: &Path, entry_name: &str) -> Result<LauncherReceipt, String> {
    let receipt_path = data_root.join(LAUNCHER_RECEIPT_FILE);
    let (receipt_bytes, _) = read_regular(&receipt_path, "Launcher receipt", MAX_RECEIPT_BYTES)
        .map_err(|error| format!("Launcher receipt is missing or invalid: {error}"))?;
    let receipt: LauncherReceipt = serde_json::from_slice(&receipt_bytes)
        .map_err(|error| format!("Launcher receipt is invalid: {error}"))?;
    if receipt.schema != LAUNCHER_RECEIPT_SCHEMA
        || receipt.entry_name != entry_name
        || receipt.length == 0
        || receipt.length > MAX_LAUNCHER_BYTES
        || !is_sha256(&receipt.sha256)
    {
        return Err("Launcher receipt has an invalid contract".to_owned());
    }
    Ok(receipt)
}

fn read_regular(path: &Path, label: &str, max: u64) -> std::io::Result<(Vec<u8>, u64)> {
    let mut file = OpenOptions::new()
        .read(true)
        .share_mode(FILE_SHARE_READ)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file()
        || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
        || metadata.len() == 0
        || metadata.len() > max
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("{label} must be a bounded regular non-reparse file"),
        ));
    }
    let length = metadata.len();
    let mut bytes = Vec::with_capacity(length as usize);
    (&mut file).take(max + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 != length || file.metadata()?.len() != length {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("{label} changed while it was read"),
        ));
    }
    Ok((bytes, length))
}

fn verify_bytes(path: &Path, expected: &LauncherArtifact) -> std::io::Result<()> {
    let (bytes, length) = read_regular(path, "staged Entry Launcher", MAX_LAUNCHER_BYTES)?;
    if length != expected.length || format!("{:x}", Sha256::digest(&bytes)) != expected.sha256 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "staged Entry Launcher content is invalid",
        ));
    }
    Ok(())
}

fn write_new_synced(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let mut file = OpenOptions::new().write(true).create_new(true).open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

fn unique_stage(target: &Path) -> Result<PathBuf, EntryManagerError> {
    let parent = target
        .parent()
        .ok_or_else(|| EntryManagerError::corrupt("Launcher has no parent"))?;
    let sequence = NEXT_STAGE.fetch_add(1, Ordering::Relaxed);
    Ok(parent.join(format!(
        ".swawkit-entry-launcher.{}.{sequence}.tmp",
        std::process::id()
    )))
}

fn is_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}
