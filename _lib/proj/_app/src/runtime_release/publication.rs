use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use sha2::{Digest, Sha256};
use windows_sys::Win32::Storage::FileSystem::{
    FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_READ,
};

use crate::atomic_file;
use crate::runtime_publication_lock::RuntimePublicationLock;

use super::{
    MAX_ARTIFACT_BYTES, MAX_MANIFEST_BYTES, RUNTIME_ARTIFACT_NAMES, RuntimeReleaseStore,
    ValidatedRuntimeRelease, invalid_data, is_reparse, validate_release,
};

static NEXT_STAGE: AtomicU64 = AtomicU64::new(0);

impl RuntimeReleaseStore {
    pub(crate) fn initialize(runtime_root: &Path, swawkit_home: &Path) -> io::Result<Self> {
        super::regular_directory(swawkit_home, "Swaw Kit Home")?;
        ensure_regular_directory(runtime_root, "Runtime root")?;
        ensure_regular_directory(&runtime_root.join("releases"), "Runtime releases directory")?;
        Self::open(runtime_root, swawkit_home)
    }

    pub(crate) fn publish_clone_from(
        &self,
        source: &RuntimeReleaseStore,
        release_id: &str,
    ) -> io::Result<ValidatedRuntimeRelease> {
        if self.swawkit_home != source.swawkit_home {
            return Err(invalid_data(
                "Runtime Release clone source and target must share SWAWKIT_HOME",
            ));
        }
        let _lock = RuntimePublicationLock::acquire(&self.swawkit_home).map_err(invalid_data)?;
        source.validate(release_id)?;
        let target = self.releases_root.join(release_id);
        match fs::symlink_metadata(&target) {
            Ok(_) => return self.validate(release_id),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }

        let stage = stage_path(&self.releases_root, release_id);
        fs::create_dir(&stage)?;
        let result = clone_into(source, release_id, &stage)
            .and_then(|()| validate_release(&stage, release_id, &self.swawkit_home))
            .and_then(|_| match fs::rename(&stage, &target) {
                Ok(()) => Ok(()),
                Err(_error) if target.exists() => self.validate(release_id).map(|_| ()),
                Err(error) => Err(error),
            })
            .and_then(|()| self.validate(release_id));
        if stage.exists()
            && let Err(cleanup) = fs::remove_dir_all(&stage)
        {
            return Err(io::Error::new(
                result
                    .as_ref()
                    .err()
                    .map_or(io::ErrorKind::Other, io::Error::kind),
                format!(
                    "{}; staged Runtime Release could not be removed '{}': {cleanup}",
                    result.as_ref().err().map_or(
                        "Runtime Release clone did not commit".to_owned(),
                        ToString::to_string
                    ),
                    stage.display()
                ),
            ));
        }
        result
    }

    pub(crate) fn select(&self, release_id: &str) -> io::Result<()> {
        let _lock = RuntimePublicationLock::acquire(&self.swawkit_home).map_err(invalid_data)?;
        self.validate(release_id)?;
        let selector = self.runtime_root.join("current");
        match fs::symlink_metadata(&selector) {
            Ok(metadata) if metadata.is_file() && !is_reparse(&metadata) => {}
            Ok(_) => return Err(invalid_data("Runtime selector is not a regular file")),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
        atomic_file::publish(&selector, format!("{release_id}\n").as_bytes())?;
        if self.selected_release_id()? != release_id {
            return Err(invalid_data("Runtime selector publication did not persist"));
        }
        Ok(())
    }
}

fn clone_into(source: &RuntimeReleaseStore, release_id: &str, stage: &Path) -> io::Result<()> {
    let source_root = source.releases_root.join(release_id);
    for name in RUNTIME_ARTIFACT_NAMES {
        copy_regular(
            &source_root.join(name),
            &stage.join(name),
            MAX_ARTIFACT_BYTES,
        )?;
    }
    copy_regular(
        &source_root.join("manifest.json"),
        &stage.join("manifest.json"),
        MAX_MANIFEST_BYTES,
    )
}

fn copy_regular(source: &Path, target: &Path, max: u64) -> io::Result<()> {
    let mut input = OpenOptions::new()
        .read(true)
        .share_mode(FILE_SHARE_READ)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(source)?;
    let metadata = input.metadata()?;
    if !metadata.is_file()
        || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
        || metadata.len() == 0
        || metadata.len() > max
    {
        return Err(invalid_data(format!(
            "Runtime Release source member is invalid: {}",
            source.display()
        )));
    }
    let length = metadata.len();
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(target)?;
    let mut digest = Sha256::new();
    let mut copied = 0_u64;
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let count = input.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        copied += count as u64;
        if copied > max {
            return Err(invalid_data("Runtime Release source grew during clone"));
        }
        digest.update(&buffer[..count]);
        output.write_all(&buffer[..count])?;
    }
    output.sync_all()?;
    drop(output);
    if copied != length || input.metadata()?.len() != length {
        return Err(invalid_data("Runtime Release source changed during clone"));
    }
    let target_digest = digest_file(target, max)?;
    if target_digest.0 != copied || target_digest.1 != format!("{:x}", digest.finalize()) {
        return Err(invalid_data(
            "cloned Runtime Release member failed verification",
        ));
    }
    Ok(())
}

fn digest_file(path: &Path, max: u64) -> io::Result<(u64, String)> {
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || is_reparse(&metadata) || metadata.len() > max {
        return Err(invalid_data("cloned Runtime Release member is unsafe"));
    }
    let mut digest = Sha256::new();
    let mut bytes = 0_u64;
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        bytes += count as u64;
        digest.update(&buffer[..count]);
    }
    Ok((bytes, format!("{:x}", digest.finalize())))
}

fn ensure_regular_directory(path: &Path, label: &str) -> io::Result<()> {
    match fs::create_dir(path) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error),
    }
    super::regular_directory(path, label)
}

fn stage_path(releases: &Path, release_id: &str) -> PathBuf {
    let sequence = NEXT_STAGE.fetch_add(1, Ordering::Relaxed);
    releases.join(format!(
        ".{release_id}.{}.{sequence}.tmp",
        std::process::id()
    ))
}
