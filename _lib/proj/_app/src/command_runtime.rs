use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read};
use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Component, Path, PathBuf};

use serde::Deserialize;
use sha2::{Digest, Sha256};
use windows_sys::Win32::Storage::FileSystem::{
    FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_OPEN_REPARSE_POINT,
};

pub const COMMAND_RUNTIME_SCHEMA: &str = "swawkit.proj-command-runtime/v1";
const MAX_MANIFEST_BYTES: u64 = 64 * 1024;
const MAX_TOOL_BYTES: u64 = 512 * 1024 * 1024;
const TOOL_NAMES: [&str; 2] = ["bun", "pwsh"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandRuntime {
    pub runtime_id: String,
    pub root: PathBuf,
    tools: BTreeMap<String, ToolRecord>,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct Manifest {
    schema: String,
    #[serde(rename = "runtimeId")]
    runtime_id: String,
    tools: Vec<ToolRecord>,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct ToolRecord {
    name: String,
    version: String,
    path: String,
    length: u64,
    sha256: String,
}

impl CommandRuntime {
    pub fn open(swawkit_home: &Path, runtime_id: &str) -> io::Result<Self> {
        if !is_sha256(runtime_id) {
            return Err(invalid_data("Command Runtime ID is invalid"));
        }
        let bootstrap_root = swawkit_home.join("data/proj_cache/bootstrap");
        regular_directory(&bootstrap_root, "Bootstrap data root")?;
        let root = bootstrap_root
            .join("command-runtimes/releases")
            .join(runtime_id);
        regular_directory(&root, "Command Runtime release")?;
        exact_manifest_membership(&root)?;

        let manifest_path = root.join("manifest.json");
        let manifest_bytes = read_regular_file(
            &manifest_path,
            "Command Runtime manifest",
            MAX_MANIFEST_BYTES,
        )?;
        let manifest: Manifest = serde_json::from_slice(&manifest_bytes).map_err(|error| {
            invalid_data(format!(
                "Command Runtime manifest is invalid '{}': {error}",
                manifest_path.display()
            ))
        })?;
        if manifest.schema != COMMAND_RUNTIME_SCHEMA || manifest.runtime_id != runtime_id {
            return Err(invalid_data(format!(
                "Command Runtime manifest identity is invalid: {}",
                manifest_path.display()
            )));
        }

        let mut tools = BTreeMap::new();
        for record in manifest.tools {
            validate_record(&record)?;
            if tools.insert(record.name.clone(), record).is_some() {
                return Err(invalid_data("Command Runtime repeats a tool"));
            }
        }
        if tools.keys().map(String::as_str).collect::<Vec<_>>() != TOOL_NAMES {
            return Err(invalid_data("Command Runtime tool membership is invalid"));
        }

        let mut identity = vec![COMMAND_RUNTIME_SCHEMA.to_owned()];
        for record in tools.values() {
            identity.extend([
                record.name.clone(),
                record.version.clone(),
                record.path.clone(),
                record.length.to_string(),
                record.sha256.clone(),
            ]);
        }
        let computed = format!("{:x}", Sha256::digest(identity.join("\n").as_bytes()));
        if computed != runtime_id {
            return Err(invalid_data("Command Runtime content identity is invalid"));
        }

        let runtime = Self {
            runtime_id: runtime_id.to_owned(),
            root,
            tools,
        };
        for name in TOOL_NAMES {
            runtime.validate_tool_structure(&bootstrap_root, name)?;
        }
        Ok(runtime)
    }

    pub fn tool(&self, swawkit_home: &Path, name: &str) -> io::Result<PathBuf> {
        let bootstrap_root = swawkit_home.join("data/proj_cache/bootstrap");
        self.resolve_tool(&bootstrap_root, name)
    }

    fn resolve_tool(&self, bootstrap_root: &Path, name: &str) -> io::Result<PathBuf> {
        let record = self
            .tools
            .get(name)
            .ok_or_else(|| invalid_data(format!("Command Runtime has no '{name}' tool")))?;
        let path = join_relative_path(bootstrap_root, &record.path)?;
        let actual = digest_regular_file(&path, record.length)?;
        if actual != record.sha256 {
            return Err(invalid_data(format!(
                "Command Runtime tool SHA-256 is invalid: {}",
                path.display()
            )));
        }
        Ok(path)
    }

    fn validate_tool_structure(&self, bootstrap_root: &Path, name: &str) -> io::Result<()> {
        let record = self
            .tools
            .get(name)
            .ok_or_else(|| invalid_data(format!("Command Runtime has no '{name}' tool")))?;
        let path = join_relative_path(bootstrap_root, &record.path)?;
        let file = open_regular_file(&path, "Command Runtime tool", MAX_TOOL_BYTES)?;
        if file.metadata()?.len() != record.length {
            return Err(invalid_data(format!(
                "Command Runtime tool length is invalid: {}",
                path.display()
            )));
        }
        Ok(())
    }
}

fn validate_record(record: &ToolRecord) -> io::Result<()> {
    if !TOOL_NAMES.contains(&record.name.as_str())
        || !valid_version(&record.version)
        || !valid_relative_path(&record.path)
        || record.length == 0
        || record.length > MAX_TOOL_BYTES
        || !is_sha256(&record.sha256)
    {
        return Err(invalid_data(format!(
            "Command Runtime tool record is invalid: {}",
            record.name
        )));
    }
    Ok(())
}

fn valid_version(value: &str) -> bool {
    let Some((core, suffix)) = value
        .split_once('-')
        .map_or(Some((value, None)), |(core, tail)| {
            (!tail.is_empty()).then_some((core, Some(tail)))
        })
    else {
        return false;
    };
    if core.split('.').count() != 3
        || !core
            .split('.')
            .all(|part| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit()))
    {
        return false;
    }
    suffix.is_none_or(|tail| {
        tail.bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-'))
    })
}

fn valid_relative_path(value: &str) -> bool {
    if value.is_empty() || value.contains('\\') || value.starts_with('/') || value.ends_with('/') {
        return false;
    }
    value.split('/').all(|part| {
        !part.is_empty()
            && part != "."
            && part != ".."
            && part.bytes().all(|byte| {
                byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'+' | b'-' | b' ')
            })
    })
}

fn join_relative_path(root: &Path, relative: &str) -> io::Result<PathBuf> {
    let mut path = root.to_path_buf();
    for component in Path::new(relative).components() {
        let Component::Normal(value) = component else {
            return Err(invalid_data("Command Runtime tool path is not relative"));
        };
        path.push(value);
        if path != root.join(relative) {
            regular_directory(&path, "Command Runtime tool parent")?;
        }
    }
    Ok(path)
}

fn exact_manifest_membership(root: &Path) -> io::Result<()> {
    let mut members = BTreeSet::new();
    for item in fs::read_dir(root)? {
        let item = item?;
        let name = item
            .file_name()
            .into_string()
            .map_err(|_| invalid_data("Command Runtime release contains a non-Unicode member"))?;
        let metadata = fs::symlink_metadata(item.path())?;
        if !metadata.is_file() || is_reparse(&metadata) || !members.insert(name) {
            return Err(invalid_data(
                "Command Runtime release membership is invalid",
            ));
        }
    }
    if members != BTreeSet::from(["manifest.json".to_owned()]) {
        return Err(invalid_data(
            "Command Runtime release membership is invalid",
        ));
    }
    Ok(())
}

fn digest_regular_file(path: &Path, expected_length: u64) -> io::Result<String> {
    let mut file = open_regular_file(path, "Command Runtime tool", MAX_TOOL_BYTES)?;
    if file.metadata()?.len() != expected_length {
        return Err(invalid_data(format!(
            "Command Runtime tool length is invalid: {}",
            path.display()
        )));
    }
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    let mut length = 0_u64;
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        length += count as u64;
        if length > expected_length {
            return Err(invalid_data(
                "Command Runtime tool changed while being read",
            ));
        }
        digest.update(&buffer[..count]);
    }
    if length != expected_length || file.metadata()?.len() != expected_length {
        return Err(invalid_data(
            "Command Runtime tool changed while being read",
        ));
    }
    Ok(format!("{:x}", digest.finalize()))
}

fn read_regular_file(path: &Path, label: &str, max_bytes: u64) -> io::Result<Vec<u8>> {
    let mut file = open_regular_file(path, label, max_bytes)?;
    let initial = file.metadata()?.len();
    if initial == 0 || initial > max_bytes {
        return Err(invalid_data(format!("{label} length is invalid")));
    }
    let mut bytes = Vec::with_capacity(initial as usize);
    file.by_ref().take(max_bytes + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 != initial || file.metadata()?.len() != initial {
        return Err(invalid_data(format!("{label} changed while being read")));
    }
    Ok(bytes)
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

fn is_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn is_reparse(metadata: &fs::Metadata) -> bool {
    metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

fn invalid_data(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}
