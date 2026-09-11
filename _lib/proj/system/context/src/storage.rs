use std::fs;
use std::os::windows::fs::MetadataExt;
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT;

use crate::atomic_file;
use crate::error::{ContextError, ContextResult};
use crate::model::{
    CONTEXT_SCHEMA, ContextRecord, LEGACY_CONTEXT_SCHEMA, LegacyContextRecord, MAX_CONTEXT_BYTES,
    validate_id,
};

const RESOURCE_DOCUMENT: &str = "_resource.json";
const STATE_VERSION_V1: &[u8] = b"1\n";
const STATE_VERSION: &[u8] = b"2\n";
static NEXT_STAGING_DIRECTORY: AtomicU64 = AtomicU64::new(0);

pub(crate) fn prepare_context_state(
    data_root: &Path,
    module_data_root: &Path,
) -> ContextResult<PathBuf> {
    let state_root = ensure_context_directory(data_root, &module_data_root.join("state"))?;
    let records_root = ensure_context_directory(data_root, &state_root.join("contexts"))?;
    let version = state_root.join("version");
    match publication_metadata(&version)? {
        Some(_) => {
            let content = fs::read(&version).map_err(|error| {
                ContextError::new(format!(
                    "cannot read Context state version '{}': {error}",
                    version.display()
                ))
            })?;
            match content.as_slice() {
                STATE_VERSION => {}
                STATE_VERSION_V1 => {
                    migrate_v1_state_records(&records_root)?;
                    publish_state_version(&version)?;
                }
                _ => {
                    return Err(ContextError::new(format!(
                        "unsupported Context state version: {}",
                        version.display()
                    )));
                }
            }
        }
        None => {
            migrate_flat_records(module_data_root, &records_root)?;
            publish_state_version(&version)?;
        }
    }
    Ok(records_root)
}

fn publish_state_version(path: &Path) -> ContextResult<()> {
    atomic_file::publish(path, STATE_VERSION).map_err(|error| {
        ContextError::new(format!(
            "cannot publish Context state version '{}': {error}",
            path.display()
        ))
    })
}

fn migrate_v1_state_records(records_root: &Path) -> ContextResult<()> {
    for (id, path) in resource_directories(records_root)? {
        let document = path.join(RESOURCE_DOCUMENT);
        let record = read_migratable_record(&document, &id)?;
        publish_record(&document, &record)?;
    }
    Ok(())
}

fn migrate_flat_records(module_data_root: &Path, records_root: &Path) -> ContextResult<()> {
    let entries = fs::read_dir(module_data_root).map_err(|error| {
        ContextError::new(format!(
            "cannot inspect legacy Context state '{}': {error}",
            module_data_root.display()
        ))
    })?;
    for entry in entries {
        let entry = entry.map_err(|error| ContextError::new(error.to_string()))?;
        let name = match entry.file_name().into_string() {
            Ok(name) => name,
            Err(_) => continue,
        };
        if name.starts_with('_') || name == "state" {
            continue;
        }
        let source = entry.path();
        let metadata =
            fs::symlink_metadata(&source).map_err(|error| ContextError::new(error.to_string()))?;
        if !metadata.is_dir() || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            continue;
        }
        let document = source.join(RESOURCE_DOCUMENT);
        if publication_metadata(&document)?.is_none() {
            continue;
        }
        validate_id(&name)?;
        let record = read_migratable_record(&document, &name)?;
        let destination = records_root.join(&name);
        if fs::symlink_metadata(&destination).is_ok() {
            return Err(ContextError::new(format!(
                "legacy and current Context state both contain '{name}'"
            )));
        }
        publish_new_record(records_root, &record)?;
        delete_record(module_data_root, &name)?;
    }
    Ok(())
}

pub(crate) fn ensure_context_directory(
    data_root: &Path,
    module_data_root: &Path,
) -> ContextResult<PathBuf> {
    validate_directory(data_root, "Context DataRoot")?;
    let relative = safe_module_relative(data_root, module_data_root)?;
    let mut current = data_root.to_path_buf();
    for component in relative.components() {
        let Component::Normal(segment) = component else {
            return Err(unsafe_module_root(data_root, module_data_root));
        };
        current.push(segment);
        match fs::create_dir(&current) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(error) => {
                return Err(ContextError::new(format!(
                    "cannot create Context directory '{}': {error}",
                    current.display()
                )));
            }
        }
        validate_directory(&current, "Context directory")?;
    }
    Ok(current)
}

pub(crate) fn existing_context_directory(
    data_root: &Path,
    module_data_root: &Path,
) -> ContextResult<Option<PathBuf>> {
    validate_directory(data_root, "Context DataRoot")?;
    let relative = safe_module_relative(data_root, module_data_root)?;
    let mut current = data_root.to_path_buf();
    for component in relative.components() {
        let Component::Normal(segment) = component else {
            return Err(unsafe_module_root(data_root, module_data_root));
        };
        current.push(segment);
        match fs::symlink_metadata(&current) {
            Ok(_) => validate_directory(&current, "Context directory")?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => {
                return Err(ContextError::new(format!(
                    "cannot inspect Context directory '{}': {error}",
                    current.display()
                )));
            }
        }
    }
    Ok(Some(current))
}

pub(crate) fn resource_directories(directory: &Path) -> ContextResult<Vec<(String, PathBuf)>> {
    let entries = fs::read_dir(directory).map_err(|error| {
        ContextError::new(format!(
            "cannot list Context directory '{}': {error}",
            directory.display()
        ))
    })?;
    let mut resources = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|error| ContextError::new(error.to_string()))?;
        let name = entry.file_name().into_string().map_err(|_| {
            ContextError::new(format!(
                "Context resource directory name is not valid Unicode: {}",
                entry.path().display()
            ))
        })?;
        if name.starts_with('_') {
            continue;
        }
        let path = entry.path();
        validate_directory(&path, "Context resource")?;
        validate_id(&name)?;
        resources.push((name, path));
    }
    resources.sort_by(|left, right| left.0.cmp(&right.0));
    Ok(resources)
}

pub(crate) fn context_path(directory: &Path, id: &str) -> PathBuf {
    directory.join(id).join(RESOURCE_DOCUMENT)
}

pub(crate) fn read_optional_record(
    directory: &Path,
    id: &str,
) -> ContextResult<Option<ContextRecord>> {
    let resource_directory = directory.join(id);
    match fs::symlink_metadata(&resource_directory) {
        Ok(_) => validate_directory(&resource_directory, "Context resource")?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(ContextError::new(error.to_string())),
    }
    read_record(&resource_directory.join(RESOURCE_DOCUMENT), id).map(Some)
}

pub(crate) fn read_record(path: &Path, expected_id: &str) -> ContextResult<ContextRecord> {
    let metadata = publication_metadata(path)?.ok_or_else(|| not_found(expected_id))?;
    if metadata.len() > MAX_CONTEXT_BYTES as u64 {
        return Err(ContextError::new(format!(
            "Context file exceeds {MAX_CONTEXT_BYTES} bytes: {}",
            path.display()
        )));
    }
    let content = fs::read(path).map_err(|error| {
        ContextError::new(format!("cannot read Context '{}': {error}", path.display()))
    })?;
    let record: ContextRecord = serde_json::from_slice(&content).map_err(|error| {
        ContextError::new(format!(
            "invalid Context JSON '{}': {error}",
            path.display()
        ))
    })?;
    record.validate()?;
    if record.id != expected_id {
        return Err(ContextError::new(format!(
            "Context resource '{}' declares mismatched ID '{}'",
            path.display(),
            record.id
        )));
    }
    Ok(record)
}

fn read_migratable_record(path: &Path, expected_id: &str) -> ContextResult<ContextRecord> {
    let metadata = publication_metadata(path)?.ok_or_else(|| not_found(expected_id))?;
    if metadata.len() > MAX_CONTEXT_BYTES as u64 {
        return Err(ContextError::new(format!(
            "Context file exceeds {MAX_CONTEXT_BYTES} bytes: {}",
            path.display()
        )));
    }
    let content = fs::read(path).map_err(|error| {
        ContextError::new(format!("cannot read Context '{}': {error}", path.display()))
    })?;
    let value: serde_json::Value = serde_json::from_slice(&content).map_err(|error| {
        ContextError::new(format!(
            "invalid Context JSON '{}': {error}",
            path.display()
        ))
    })?;
    let schema = value.get("schema").and_then(serde_json::Value::as_str);
    let record = match schema {
        Some(CONTEXT_SCHEMA) => serde_json::from_value::<ContextRecord>(value)
            .map_err(|error| ContextError::new(format!("invalid Context JSON: {error}")))?,
        Some(LEGACY_CONTEXT_SCHEMA) => serde_json::from_value::<LegacyContextRecord>(value)
            .map_err(|error| ContextError::new(format!("invalid legacy Context JSON: {error}")))?
            .into_current()?,
        _ => {
            return Err(ContextError::new(format!(
                "unsupported Context schema in '{}'",
                path.display()
            )));
        }
    };
    record.validate()?;
    if record.id != expected_id {
        return Err(ContextError::new(format!(
            "Context resource '{}' declares mismatched ID '{}'",
            path.display(),
            record.id
        )));
    }
    Ok(record)
}

pub(crate) fn publish_new_record(directory: &Path, record: &ContextRecord) -> ContextResult<()> {
    let target = directory.join(&record.id);
    if fs::symlink_metadata(&target).is_ok() {
        return Err(ContextError::new(format!(
            "Context already exists: {}",
            record.id
        )));
    }
    let sequence = NEXT_STAGING_DIRECTORY.fetch_add(1, Ordering::Relaxed);
    let staging = directory.join(format!("_partial-{}-{sequence}", std::process::id()));
    fs::create_dir(&staging).map_err(|error| {
        ContextError::new(format!(
            "cannot create staged Context resource '{}': {error}",
            staging.display()
        ))
    })?;
    let result = publish_record(&staging.join(RESOURCE_DOCUMENT), record).and_then(|_| {
        fs::rename(&staging, &target).map_err(|error| {
            ContextError::new(format!(
                "cannot publish Context resource '{}': {error}",
                target.display()
            ))
        })
    });
    if result.is_err() {
        let _ = fs::remove_file(staging.join(RESOURCE_DOCUMENT));
        let _ = fs::remove_dir(&staging);
    }
    result
}

pub(crate) fn publish_record(path: &Path, record: &ContextRecord) -> ContextResult<()> {
    record.validate()?;
    let mut content = serde_json::to_vec_pretty(record)
        .map_err(|error| ContextError::new(format!("cannot serialize Context: {error}")))?;
    content.push(b'\n');
    if content.len() > MAX_CONTEXT_BYTES {
        return Err(ContextError::new(format!(
            "serialized Context accepts at most {MAX_CONTEXT_BYTES} bytes"
        )));
    }
    publication_metadata(path)?;
    atomic_file::publish(path, &content).map_err(|error| {
        ContextError::new(format!(
            "cannot publish Context '{}': {error}",
            path.display()
        ))
    })
}

pub(crate) fn delete_record(directory: &Path, id: &str) -> ContextResult<()> {
    let resource_directory = directory.join(id);
    validate_directory(&resource_directory, "Context resource")?;
    let entries = fs::read_dir(&resource_directory)
        .map_err(|error| ContextError::new(error.to_string()))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| ContextError::new(error.to_string()))?;
    if entries.len() != 1 || entries[0].file_name() != RESOURCE_DOCUMENT {
        return Err(ContextError::new(format!(
            "Context resource contains unexpected files and cannot be deleted safely: {}",
            resource_directory.display()
        )));
    }
    let document = resource_directory.join(RESOURCE_DOCUMENT);
    publication_metadata(&document)?.ok_or_else(|| not_found(id))?;
    fs::remove_file(&document).map_err(|error| ContextError::new(error.to_string()))?;
    fs::remove_dir(&resource_directory).map_err(|error| ContextError::new(error.to_string()))
}

fn publication_metadata(path: &Path) -> ContextResult<Option<fs::Metadata>> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(ContextError::new(error.to_string())),
    };
    if !metadata.is_file() || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(ContextError::new(format!(
            "Context publication must be a regular file: {}",
            path.display()
        )));
    }
    Ok(Some(metadata))
}

fn safe_module_relative<'a>(data_root: &'a Path, module_root: &'a Path) -> ContextResult<&'a Path> {
    let relative = module_root
        .strip_prefix(data_root)
        .map_err(|_| unsafe_module_root(data_root, module_root))?;
    if relative.as_os_str().is_empty()
        || relative
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        Err(unsafe_module_root(data_root, module_root))
    } else {
        Ok(relative)
    }
}

fn unsafe_module_root(data_root: &Path, module_root: &Path) -> ContextError {
    ContextError::new(format!(
        "Context module DataRoot is not a safe child of '{}': {}",
        data_root.display(),
        module_root.display()
    ))
}

pub(crate) fn validate_directory(path: &Path, label: &str) -> ContextResult<()> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        ContextError::new(format!(
            "cannot inspect {label} '{}': {error}",
            path.display()
        ))
    })?;
    if !metadata.is_dir() || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        Err(ContextError::new(format!(
            "{label} must be a regular directory: {}",
            path.display()
        )))
    } else {
        Ok(())
    }
}

fn not_found(id: &str) -> ContextError {
    ContextError::new(format!("Context not found: {id}"))
}
