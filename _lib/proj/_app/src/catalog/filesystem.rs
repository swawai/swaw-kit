use std::{
    fs, io,
    path::{Path, PathBuf},
};

use super::invalid_data;

#[derive(Debug)]
pub(super) struct ChildDirectory {
    pub(super) name: String,
    pub(super) path: PathBuf,
}

pub(super) fn child_directories(directory: &Path) -> io::Result<Vec<ChildDirectory>> {
    let mut children = Vec::new();
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        let metadata = fs::symlink_metadata(entry.path())?;
        if is_reparse_point(&metadata) || !metadata.is_dir() {
            continue;
        }
        let Ok(name) = entry.file_name().into_string() else {
            continue;
        };
        children.push(ChildDirectory {
            name,
            path: entry.path(),
        });
    }
    children.sort_by(|left, right| left.name.cmp(&right.name));
    Ok(children)
}

#[derive(Debug)]
pub(super) struct FileCandidate {
    pub(super) name: String,
    pub(super) path: PathBuf,
    pub(super) reparse_point: bool,
}

pub(super) fn directory_files(directory: &Path) -> io::Result<Vec<FileCandidate>> {
    let mut files = Vec::new();
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        let metadata = fs::symlink_metadata(entry.path())?;
        let reparse_point = is_reparse_point(&metadata);
        if !metadata.is_file() && !reparse_point {
            continue;
        }
        let Ok(name) = entry.file_name().into_string() else {
            continue;
        };
        files.push(FileCandidate {
            name,
            path: entry.path(),
            reparse_point,
        });
    }
    Ok(files)
}

#[derive(Debug)]
pub(super) struct NamedDirectory {
    pub(super) name: String,
    pub(super) path: PathBuf,
    pub(super) reparse_point: bool,
}

pub(super) fn named_directories(
    directory: &Path,
    expected_name: &str,
) -> io::Result<Vec<NamedDirectory>> {
    let mut matches = Vec::new();
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        let metadata = fs::symlink_metadata(entry.path())?;
        let reparse_point = is_reparse_point(&metadata);
        if !metadata.is_dir() && !reparse_point {
            continue;
        }
        let Ok(name) = entry.file_name().into_string() else {
            continue;
        };
        if name.eq_ignore_ascii_case(expected_name) {
            matches.push(NamedDirectory {
                name,
                path: entry.path(),
                reparse_point,
            });
        }
    }
    Ok(matches)
}

pub(super) fn assert_command_root(root: &Path) -> io::Result<()> {
    let metadata = fs::symlink_metadata(root)?;
    if !metadata.is_dir() {
        return invalid_data(format!(
            "command root is not a directory: {}",
            root.display()
        ));
    }
    if is_reparse_point(&metadata) {
        return invalid_data(format!(
            "command root cannot be a reparse point: {}",
            root.display()
        ));
    }
    Ok(())
}

#[cfg(windows)]
fn is_reparse_point(metadata: &fs::Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;

    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0400;
    metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

#[cfg(not(windows))]
fn is_reparse_point(metadata: &fs::Metadata) -> bool {
    metadata.file_type().is_symlink()
}

pub(super) fn absolute_path(path: &Path) -> io::Result<PathBuf> {
    std::path::absolute(path)
}
