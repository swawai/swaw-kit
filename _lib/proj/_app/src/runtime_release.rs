use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read};
use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

use serde::Deserialize;
use sha2::{Digest, Sha256};
use windows_sys::Win32::Storage::FileSystem::{
    FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_OPEN_REPARSE_POINT,
};

use crate::command_runtime::CommandRuntime;
use crate::context::EntryContext;

pub const RUNTIME_RELEASE_SCHEMA: &str = "swawkit.proj-release-set/v4";
pub const RUNTIME_ARTIFACT_NAMES: [&str; 4] = [
    "swawkit-proj-dev.exe",
    "swawkit-proj-host.exe",
    "swawkit-proj-module.exe",
    "swawkit-proj.exe",
];
const SELECTOR_BYTES: u64 = 65;
const MAX_MANIFEST_BYTES: u64 = 1024 * 1024;
const MAX_ARTIFACT_BYTES: u64 = 512 * 1024 * 1024;

#[derive(Debug, Clone)]
pub struct RuntimeReleaseStore {
    runtime_root: PathBuf,
    releases_root: PathBuf,
}

#[derive(Debug, Clone)]
pub struct ValidatedRuntimeRelease {
    pub release_id: String,
    pub root: PathBuf,
    pub command_runtime_id: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    schema: String,
    #[serde(rename = "releaseId")]
    release_id: String,
    #[serde(rename = "commandRuntimeId")]
    command_runtime_id: String,
    artifacts: Vec<ArtifactRecord>,
}

struct InspectedRelease {
    command_runtime_id: String,
    records: BTreeMap<String, ArtifactRecord>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct ArtifactRecord {
    name: String,
    length: u64,
    sha256: String,
}

impl RuntimeReleaseStore {
    pub fn open(swawkit_home: &Path) -> io::Result<Self> {
        regular_directory(swawkit_home, "Swaw Kit Home")?;
        let library_root = swawkit_home.join("_lib");
        regular_directory(&library_root, "Swaw Kit library root")?;
        let proj_root = library_root.join("proj");
        regular_directory(&proj_root, "Proj root")?;
        let runtime_root = proj_root.join("_bin");
        regular_directory(&runtime_root, "Runtime root")?;
        let releases_root = runtime_root.join("releases");
        regular_directory(&releases_root, "Runtime releases directory")?;
        Ok(Self {
            runtime_root,
            releases_root,
        })
    }

    pub fn selected_release_id(&self) -> io::Result<String> {
        read_selector(&self.runtime_root.join("current"))
    }

    pub fn releases_root(&self) -> &Path {
        &self.releases_root
    }

    pub fn validate(&self, release_id: &str) -> io::Result<ValidatedRuntimeRelease> {
        if !is_release_id(release_id.as_bytes()) {
            return Err(invalid_data("Runtime Release ID is invalid"));
        }
        let root = self.releases_root.join(release_id);
        let inspected = validate_release(&root, release_id, &swawkit_home_from_root(&root)?)?;
        Ok(ValidatedRuntimeRelease {
            release_id: release_id.to_owned(),
            root,
            command_runtime_id: inspected.command_runtime_id,
        })
    }
}

pub fn selected_release_id(context: &EntryContext) -> io::Result<String> {
    RuntimeReleaseStore::open(&context.swawkit_home)?.selected_release_id()
}

/// Validates the cheap, immutable structure of the release that owns this
/// process. The selected release may already have changed; a running process
/// remains bound to the directory from which Windows loaded it.
pub fn validate_running_release(context: &EntryContext) -> io::Result<()> {
    let root = context
        .product_executable
        .parent()
        .ok_or_else(|| invalid_data("Runtime product executable has no Release directory"))?;
    let expected_root = context
        .command_root()
        .join("_bin/releases")
        .join(&context.release_id);
    if root != expected_root {
        return Err(invalid_data(format!(
            "running Runtime product does not belong to its declared Release: {}",
            context.product_executable.display()
        )));
    }
    let name = context
        .product_executable
        .file_name()
        .and_then(|value| value.to_str())
        .filter(|value| RUNTIME_ARTIFACT_NAMES.contains(value))
        .ok_or_else(|| invalid_data("running Runtime product name is invalid"))?;
    let inspected = inspect_release(root, &context.release_id)?;
    if !inspected.records.contains_key(name) {
        return Err(invalid_data(
            "running Runtime product is absent from its Release",
        ));
    }
    CommandRuntime::open(&context.swawkit_home, &inspected.command_runtime_id)?;
    Ok(())
}

pub fn command_runtime(context: &EntryContext) -> io::Result<CommandRuntime> {
    let root = context
        .product_executable
        .parent()
        .ok_or_else(|| invalid_data("Runtime product executable has no Release directory"))?;
    let inspected = inspect_release(root, &context.release_id)?;
    CommandRuntime::open(&context.swawkit_home, &inspected.command_runtime_id)
}

/// Validates the one sibling Runtime artifact immediately before it is
/// started. This keeps the ordinary CLI path cheap while preserving the
/// content-addressed boundary for the product that will actually execute.
pub fn validate_product(path: &Path) -> io::Result<()> {
    let root = path
        .parent()
        .ok_or_else(|| invalid_data("Runtime product has no Release directory"))?;
    let release_id = root
        .file_name()
        .and_then(|value| value.to_str())
        .filter(|value| is_release_id(value.as_bytes()))
        .ok_or_else(|| invalid_data("Runtime product Release ID is invalid"))?;
    let name = path
        .file_name()
        .and_then(|value| value.to_str())
        .filter(|value| RUNTIME_ARTIFACT_NAMES.contains(value))
        .ok_or_else(|| invalid_data("Runtime product name is invalid"))?;
    if root.join(name) != path {
        return Err(invalid_data("Runtime product path is not canonical"));
    }
    let inspected = inspect_release(root, release_id)?;
    let record = inspected
        .records
        .get(name)
        .expect("validated Runtime membership");
    let actual = digest_regular_file(path, record.length)?;
    if actual != record.sha256 {
        return Err(invalid_data(format!(
            "Runtime product SHA-256 is invalid: {}",
            path.display()
        )));
    }
    Ok(())
}

fn read_selector(path: &Path) -> io::Result<String> {
    let bytes = read_regular_file(path, "Runtime selector", SELECTOR_BYTES)?;
    if bytes.len() as u64 != SELECTOR_BYTES {
        return Err(invalid_data(format!(
            "Runtime selector must contain exactly 64 lowercase hexadecimal bytes and a newline: {}",
            path.display()
        )));
    }
    let release_id = bytes
        .strip_suffix(b"\n")
        .filter(|value| is_release_id(value))
        .ok_or_else(|| invalid_data("Runtime selector content is invalid"))?;
    String::from_utf8(release_id.to_vec())
        .map_err(|_| invalid_data("Runtime selector is not UTF-8"))
}

fn validate_release(
    root: &Path,
    expected_id: &str,
    swawkit_home: &Path,
) -> io::Result<InspectedRelease> {
    let inspected = inspect_release(root, expected_id)?;
    for name in RUNTIME_ARTIFACT_NAMES {
        let record = inspected.records.get(name).expect("validated membership");
        let path = root.join(name);
        let actual = digest_regular_file(&path, record.length)?;
        if actual != record.sha256 {
            return Err(invalid_data(format!(
                "Runtime Release artifact SHA-256 is invalid: {}",
                path.display()
            )));
        }
    }
    CommandRuntime::open(swawkit_home, &inspected.command_runtime_id)?;
    Ok(inspected)
}

fn inspect_release(root: &Path, expected_id: &str) -> io::Result<InspectedRelease> {
    if !is_release_id(expected_id.as_bytes()) {
        return Err(invalid_data("Runtime Release ID is invalid"));
    }
    regular_directory(root, "Runtime Release directory")?;
    let manifest_path = root.join("manifest.json");
    let manifest_bytes = read_regular_file(
        &manifest_path,
        "Runtime Release manifest",
        MAX_MANIFEST_BYTES,
    )?;
    let manifest: Manifest = serde_json::from_slice(&manifest_bytes).map_err(|error| {
        invalid_data(format!(
            "Runtime Release manifest is invalid '{}': {error}",
            manifest_path.display()
        ))
    })?;
    if manifest.schema != RUNTIME_RELEASE_SCHEMA
        || manifest.release_id != expected_id
        || !is_sha256(&manifest.command_runtime_id)
    {
        return Err(invalid_data(format!(
            "Runtime Release manifest identity is invalid: {}",
            manifest_path.display()
        )));
    }

    let mut records = BTreeMap::new();
    for record in manifest.artifacts {
        if !RUNTIME_ARTIFACT_NAMES.contains(&record.name.as_str())
            || record.length == 0
            || record.length > MAX_ARTIFACT_BYTES
            || !is_sha256(&record.sha256)
            || records.insert(record.name.clone(), record).is_some()
        {
            return Err(invalid_data(format!(
                "Runtime Release artifact record is invalid: {}",
                manifest_path.display()
            )));
        }
    }
    if records.len() != RUNTIME_ARTIFACT_NAMES.len() {
        return Err(invalid_data(format!(
            "Runtime Release membership is invalid: {}",
            manifest_path.display()
        )));
    }

    let expected_files = RUNTIME_ARTIFACT_NAMES
        .iter()
        .copied()
        .chain(["manifest.json"])
        .map(str::to_owned)
        .collect::<BTreeSet<_>>();
    let mut actual_files = BTreeSet::new();
    for item in fs::read_dir(root)? {
        let item = item?;
        let name = item
            .file_name()
            .into_string()
            .map_err(|_| invalid_data("Runtime Release contains a non-Unicode member"))?;
        if !actual_files.insert(name.clone()) {
            return Err(invalid_data("Runtime Release contains duplicate members"));
        }
        let metadata = fs::symlink_metadata(item.path())?;
        if !metadata.is_file() || is_reparse(&metadata) {
            return Err(invalid_data(format!(
                "Runtime Release member is not a regular file: {}",
                item.path().display()
            )));
        }
    }
    if actual_files != expected_files {
        return Err(invalid_data(format!(
            "Runtime Release directory membership is invalid: {}",
            root.display()
        )));
    }

    let mut identity = vec![
        RUNTIME_RELEASE_SCHEMA.to_owned(),
        manifest.command_runtime_id.clone(),
    ];
    for (name, record) in &records {
        let path = root.join(name);
        let file = open_regular_file(&path, "Runtime Release artifact", MAX_ARTIFACT_BYTES)?;
        if file.metadata()?.len() != record.length {
            return Err(invalid_data(format!(
                "Runtime Release artifact length is invalid: {}",
                path.display()
            )));
        }
        identity.extend([
            name.to_owned(),
            record.length.to_string(),
            record.sha256.clone(),
        ]);
    }
    let computed = format!("{:x}", Sha256::digest(identity.join("\n").as_bytes()));
    if computed != expected_id {
        return Err(invalid_data(format!(
            "Runtime Release content identity does not match its directory: {}",
            root.display()
        )));
    }
    Ok(InspectedRelease {
        command_runtime_id: manifest.command_runtime_id,
        records,
    })
}

fn swawkit_home_from_root(release_root: &Path) -> io::Result<PathBuf> {
    let releases_root = release_root
        .parent()
        .filter(|path| path.file_name().is_some_and(|name| name == "releases"))
        .ok_or_else(|| invalid_data("Runtime Release path is invalid"))?;
    let runtime_root = releases_root
        .parent()
        .filter(|path| path.file_name().is_some_and(|name| name == "_bin"))
        .ok_or_else(|| invalid_data("Runtime Release path is invalid"))?;
    let proj_root = runtime_root
        .parent()
        .filter(|path| path.file_name().is_some_and(|name| name == "proj"))
        .ok_or_else(|| invalid_data("Runtime Release path is invalid"))?;
    let library_root = proj_root
        .parent()
        .filter(|path| path.file_name().is_some_and(|name| name == "_lib"))
        .ok_or_else(|| invalid_data("Runtime Release path is invalid"))?;
    library_root
        .parent()
        .map(Path::to_path_buf)
        .ok_or_else(|| invalid_data("Runtime Release path is invalid"))
}

fn digest_regular_file(path: &Path, expected_length: u64) -> io::Result<String> {
    let mut file = open_regular_file(path, "Runtime Release artifact", MAX_ARTIFACT_BYTES)?;
    if file.metadata()?.len() != expected_length {
        return Err(invalid_data(format!(
            "Runtime Release artifact length is invalid: {}",
            path.display()
        )));
    }
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        digest.update(&buffer[..count]);
    }
    Ok(format!("{:x}", digest.finalize()))
}

fn read_regular_file(path: &Path, label: &str, max_bytes: u64) -> io::Result<Vec<u8>> {
    let mut file = open_regular_file(path, label, max_bytes)?;
    let initial_length = file.metadata()?.len();
    if initial_length == 0 || initial_length > max_bytes {
        return Err(invalid_data(format!(
            "{label} length is invalid: {}",
            path.display()
        )));
    }
    read_bounded_contents(&mut file, path, label, max_bytes, initial_length)
}

fn read_bounded_contents(
    file: &mut File,
    path: &Path,
    label: &str,
    max_bytes: u64,
    initial_length: u64,
) -> io::Result<Vec<u8>> {
    let mut bytes = Vec::with_capacity(initial_length.min(max_bytes) as usize);
    file.by_ref()
        .take(max_bytes.saturating_add(1))
        .read_to_end(&mut bytes)?;
    let final_length = file.metadata()?.len();
    if bytes.len() as u64 > max_bytes {
        return Err(invalid_data(format!(
            "{label} exceeds its size limit while being read: {}",
            path.display()
        )));
    }
    if final_length != initial_length || final_length != bytes.len() as u64 {
        return Err(invalid_data(format!(
            "{label} changed while being read: {}",
            path.display()
        )));
    }
    Ok(bytes)
}

fn regular_directory(path: &Path, label: &str) -> io::Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_dir() || is_reparse(&metadata) {
        return Err(invalid_data(format!(
            "{label} must be a regular directory: {}",
            path.display()
        )));
    }
    Ok(())
}

fn open_regular_file(path: &Path, label: &str, max_bytes: u64) -> io::Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || is_reparse(&metadata) || metadata.len() > max_bytes {
        return Err(invalid_data(format!(
            "{label} must be a bounded regular file: {}",
            path.display()
        )));
    }
    Ok(file)
}

fn is_release_id(value: &[u8]) -> bool {
    value.len() == 64
        && value
            .iter()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte))
}

fn is_sha256(value: &str) -> bool {
    is_release_id(value.as_bytes())
}

fn is_reparse(metadata: &fs::Metadata) -> bool {
    metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

fn invalid_data(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}

#[cfg(test)]
pub(crate) mod tests;
