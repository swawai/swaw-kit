use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use crate::atomic_file;
use crate::command::{CommandError, CommandResult};

use super::NativeCommandPublication;
use super::release::{self, MAX_RELEASE_BYTES, RELEASE_FILE, SourceContract};
use super::storage::{
    checked_directory, ensure_descendant, hex_sha256, invalid, read_regular_file,
    read_release_selector,
};

const RELEASES_DIRECTORY: &str = "releases";
const EXECUTABLE_NAME: &str = "run.exe";
static NEXT_STAGE: AtomicU64 = AtomicU64::new(0);

pub(super) fn resolve(
    module_data_root: &Path,
    expected_owner: &str,
    expected_source: &SourceContract,
) -> CommandResult<PathBuf> {
    let export = checked_directory(&module_data_root.join("export"), "native export")
        .map_err(uninstantiated)?;
    let capability = checked_directory(&export.join("command"), "native command export")?;
    let selector = capability.join("current");
    let release_id = read_release_selector(&selector, "native command release selector")
        .map_err(uninstantiated)?;
    let releases = checked_directory(
        &capability.join(RELEASES_DIRECTORY),
        "native command releases",
    )?;
    let release = checked_directory(&releases.join(&release_id), "native command release")?;
    let release_document = read_regular_file(
        &release.join(RELEASE_FILE),
        "native command release manifest",
    )?;
    if release_document.len() > MAX_RELEASE_BYTES {
        return invalid(format!(
            "native command release manifest exceeds {MAX_RELEASE_BYTES} bytes: '{}'",
            release.display()
        ));
    }
    let actual_release_id = hex_sha256(&release_document);
    if actual_release_id != release_id {
        return invalid(format!(
            "native command release manifest integrity check failed for '{}': selector={release_id}, manifest={actual_release_id}",
            release.display()
        ));
    }
    let manifest = release::validate_release(&release_document, expected_owner, expected_source)?;
    let executable = release.join(EXECUTABLE_NAME);
    let bytes = read_regular_file(&executable, "native command executable")?;
    if bytes.is_empty() {
        return invalid(format!(
            "native command executable is empty: '{}'",
            executable.display()
        ));
    }
    release::validate_artifact(&manifest, &bytes)?;
    Ok(executable)
}

pub(super) fn publish(
    module_data_root: &Path,
    bytes: &[u8],
    release_document: &[u8],
) -> Result<NativeCommandPublication, String> {
    release::validate_publication(release_document, bytes)?;
    let release_id = hex_sha256(release_document);
    let capability = ensure_descendant(
        module_data_root,
        &module_data_root.join("export/command"),
        "native command export",
    )?;
    let releases = ensure_descendant(
        &capability,
        &capability.join(RELEASES_DIRECTORY),
        "native command releases",
    )?;
    let release = releases.join(&release_id);
    match fs::symlink_metadata(&release) {
        Ok(_) => validate_existing_release(&release, bytes, release_document)?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            publish_immutable_release(&releases, &release, bytes, release_document)?;
        }
        Err(error) => {
            return Err(format!(
                "cannot inspect native command release '{}': {error}",
                release.display()
            ));
        }
    }

    let changed = publish_selector(&capability, &release_id)?;
    Ok(NativeCommandPublication {
        release_id,
        changed,
    })
}

fn validate_existing_release(
    release: &Path,
    bytes: &[u8],
    release_document: &[u8],
) -> Result<(), String> {
    checked_directory(release, "native command release").map_err(|error| error.to_string())?;
    let existing = read_regular_file(&release.join(EXECUTABLE_NAME), "native command executable")
        .map_err(|error| error.to_string())?;
    if existing != bytes {
        return Err(format!(
            "native command release collision or corruption: {}",
            release.display()
        ));
    }
    let existing_document = read_regular_file(
        &release.join(RELEASE_FILE),
        "native command release manifest",
    )
    .map_err(|error| error.to_string())?;
    if existing_document != release_document {
        return Err(format!(
            "native command release manifest collision or corruption: {}",
            release.display()
        ));
    }
    Ok(())
}

fn publish_selector(capability: &Path, release_id: &str) -> Result<bool, String> {
    let selector = capability.join("current");
    let selector_bytes = format!("{release_id}\n").into_bytes();
    let changed = match fs::symlink_metadata(&selector) {
        Ok(_) => {
            read_regular_file(&selector, "native command release selector")
                .map_err(|error| error.to_string())?
                != selector_bytes
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => true,
        Err(error) => {
            return Err(format!(
                "cannot inspect native command release selector '{}': {error}",
                selector.display()
            ));
        }
    };
    if changed {
        atomic_file::publish(&selector, &selector_bytes).map_err(|error| {
            format!(
                "cannot publish native command release selector '{}': {error}",
                selector.display()
            )
        })?;
    }
    Ok(changed)
}

fn publish_immutable_release(
    releases: &Path,
    release: &Path,
    bytes: &[u8],
    release_document: &[u8],
) -> Result<(), String> {
    let sequence = NEXT_STAGE.fetch_add(1, Ordering::Relaxed);
    let stage = releases.join(format!(
        ".instantiate.{}.{sequence}.stage",
        std::process::id()
    ));
    fs::create_dir(&stage).map_err(|error| {
        format!(
            "cannot create native command release stage '{}': {error}",
            stage.display()
        )
    })?;
    let executable = stage.join(EXECUTABLE_NAME);
    let prepared = (|| -> std::io::Result<()> {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&executable)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        let mut manifest = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(stage.join(RELEASE_FILE))?;
        manifest.write_all(release_document)?;
        manifest.sync_all()
    })();
    if let Err(error) = prepared {
        let _ = fs::remove_dir_all(&stage);
        return Err(format!(
            "cannot prepare native command release '{}': {error}",
            stage.display()
        ));
    }
    fs::rename(&stage, release).map_err(|error| {
        format!(
            "cannot publish immutable native command release '{}': {error}; recovery stage: '{}'",
            release.display(),
            stage.display()
        )
    })
}

fn uninstantiated(error: CommandError) -> CommandError {
    CommandError::new(format!(
        "{error}. the module has not been instantiated; publish its run.exe before execution"
    ))
}
