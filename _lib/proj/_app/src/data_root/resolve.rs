use std::error::Error;
use std::ffi::OsStr;
use std::fmt;
use std::fs;
use std::os::windows::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT;

use super::lease::DataRootBindingLease;

#[derive(Clone, Copy)]
pub struct ResolveDataRootRequest<'a> {
    pub swawkit_home: &'a Path,
    pub entry_file: &'a Path,
}

#[derive(Clone)]
pub struct ResolvedDataRoot {
    path: PathBuf,
    _lease: Arc<DataRootBindingLease>,
}

impl ResolvedDataRoot {
    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn runtime_root(&self) -> PathBuf {
        self.path.join("runtime")
    }
}

impl fmt::Debug for ResolvedDataRoot {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ResolvedDataRoot")
            .field("path", &self.path)
            .finish_non_exhaustive()
    }
}

impl PartialEq for ResolvedDataRoot {
    fn eq(&self, other: &Self) -> bool {
        self.path == other.path
    }
}

impl Eq for ResolvedDataRoot {}

pub fn resolve_data_root(
    request: ResolveDataRootRequest<'_>,
) -> Result<ResolvedDataRoot, ResolveDataRootError> {
    let swawkit_home = required_directory(request.swawkit_home, "SWAWKIT_HOME")?;
    let entry_file = absolute(request.entry_file, "project entry file")?;
    if !entry_file.is_file() {
        return Err(ResolveDataRootError::invalid(format!(
            "project entry file does not exist: {}",
            entry_file.display()
        )));
    }
    if entry_file.parent() != Some(swawkit_home.as_path()) {
        return Err(ResolveDataRootError::invalid(format!(
            "project entry file must belong directly to SWAWKIT_HOME '{}': {}",
            swawkit_home.display(),
            entry_file.display()
        )));
    }
    if !entry_file
        .extension()
        .and_then(OsStr::to_str)
        .is_some_and(|extension| extension.eq_ignore_ascii_case("exe"))
    {
        return Err(ResolveDataRootError::invalid(format!(
            "project entry file must have an .exe suffix: {}",
            entry_file.display()
        )));
    }
    let entry_name = entry_file
        .file_stem()
        .and_then(OsStr::to_str)
        .filter(|name| !name.trim().is_empty())
        .ok_or_else(|| ResolveDataRootError::invalid("project entry has no usable file name"))?;
    let data_parent = swawkit_home.join("data");
    let data_root_name = if entry_name.eq_ignore_ascii_case("swawkit") {
        "swawkit"
    } else {
        entry_name
    };
    let data_root = data_parent.join(format!("proj.{data_root_name}"));
    match fs::symlink_metadata(&data_parent) {
        Ok(metadata) if is_regular_directory(&metadata) => {}
        Ok(_) => {
            return Err(ResolveDataRootError::invalid(format!(
                "Entry data directory must be a regular non-reparse directory: {}",
                data_parent.display()
            )));
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Err(uninitialized(entry_name, &data_root));
        }
        Err(error) => {
            return Err(ResolveDataRootError::io(
                "inspect Entry data directory",
                &data_parent,
                error,
            ));
        }
    }

    match fs::symlink_metadata(&data_root) {
        Ok(metadata) if is_regular_directory(&metadata) => {}
        Ok(_) => {
            return Err(ResolveDataRootError::invalid(format!(
                "Entry DataRoot must be a regular non-reparse directory: {}",
                data_root.display()
            )));
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Err(uninitialized(entry_name, &data_root));
        }
        Err(error) => {
            return Err(ResolveDataRootError::io(
                "inspect Entry DataRoot",
                &data_root,
                error,
            ));
        }
    }

    match DataRootBindingLease::acquire(&data_root) {
        Ok(lease) => Ok(ResolvedDataRoot {
            path: data_root,
            _lease: Arc::new(lease),
        }),
        Err(error) => Err(ResolveDataRootError::new(
            ResolveDataRootErrorKind::Io,
            error.to_string(),
        )),
    }
}

fn is_regular_directory(metadata: &fs::Metadata) -> bool {
    metadata.is_dir() && metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT == 0
}

fn uninitialized(entry_name: &str, data_root: &Path) -> ResolveDataRootError {
    ResolveDataRootError::new(
        ResolveDataRootErrorKind::Uninitialized,
        format!(
            "Entry '{entry_name}' is not initialized; expected DataRoot: {}",
            data_root.display()
        ),
    )
}

fn required_directory(path: &Path, label: &str) -> Result<PathBuf, ResolveDataRootError> {
    let path = absolute(path, label)?;
    match fs::symlink_metadata(&path) {
        Ok(metadata) if is_regular_directory(&metadata) => {}
        Ok(_) => {
            return Err(ResolveDataRootError::invalid(format!(
                "{label} must be a regular non-reparse directory: {}",
                path.display()
            )));
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Err(ResolveDataRootError::invalid(format!(
                "{label} does not exist: {}",
                path.display()
            )));
        }
        Err(error) => return Err(ResolveDataRootError::io("inspect directory", &path, error)),
    }
    Ok(path)
}

fn absolute(path: &Path, label: &str) -> Result<PathBuf, ResolveDataRootError> {
    std::path::absolute(path).map_err(|error| {
        ResolveDataRootError::invalid(format!(
            "invalid {label} path '{}': {error}",
            path.display()
        ))
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResolveDataRootErrorKind {
    Uninitialized,
    Invalid,
    Io,
}

#[derive(Debug)]
pub struct ResolveDataRootError {
    kind: ResolveDataRootErrorKind,
    message: String,
}

impl ResolveDataRootError {
    fn new(kind: ResolveDataRootErrorKind, message: String) -> Self {
        Self { kind, message }
    }

    fn invalid(message: impl Into<String>) -> Self {
        Self::new(ResolveDataRootErrorKind::Invalid, message.into())
    }

    fn io(action: &str, path: &Path, error: std::io::Error) -> Self {
        Self::new(
            ResolveDataRootErrorKind::Io,
            format!("cannot {action} '{}': {error}", path.display()),
        )
    }

    pub fn kind(&self) -> ResolveDataRootErrorKind {
        self.kind
    }
}

impl fmt::Display for ResolveDataRootError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl Error for ResolveDataRootError {}

#[cfg(test)]
mod tests;
