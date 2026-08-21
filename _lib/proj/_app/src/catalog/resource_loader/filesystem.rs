use std::{
    fs::{self, Metadata, OpenOptions},
    io::Read,
    path::{Path, PathBuf},
};

const MAX_DIRECTORY_ENTRIES: usize = 512;
const MAX_PROTOCOL_FILE_BYTES: u64 = 64 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum EntryKind {
    Directory,
    File,
    Other,
}

#[derive(Debug, Clone)]
pub(super) struct SafeEntry {
    pub(super) name: String,
    pub(super) path: PathBuf,
    pub(super) kind: EntryKind,
    pub(super) reparse_point: bool,
}

#[derive(Debug)]
pub(super) struct DirectorySnapshot {
    pub(super) path: PathBuf,
    pub(super) entries: Vec<SafeEntry>,
}

impl DirectorySnapshot {
    pub(super) fn open(path: &Path) -> Result<Self, String> {
        assert_plain_directory(path)?;
        let mut entries = Vec::new();
        let reader = fs::read_dir(path)
            .map_err(|error| format!("cannot inspect directory '{}': {error}", path.display()))?;
        for entry in reader {
            let entry = entry.map_err(|error| {
                format!(
                    "cannot inspect an entry below '{}': {error}",
                    path.display()
                )
            })?;
            if entries.len() == MAX_DIRECTORY_ENTRIES {
                return Err(format!(
                    "directory '{}' contains more than {MAX_DIRECTORY_ENTRIES} entries",
                    path.display()
                ));
            }
            let name = entry.file_name().into_string().map_err(|_| {
                format!(
                    "directory '{}' contains a non-Unicode entry name",
                    path.display()
                )
            })?;
            let entry_path = entry.path();
            let metadata = fs::symlink_metadata(&entry_path)
                .map_err(|error| format!("cannot inspect '{}': {error}", entry_path.display()))?;
            let kind = if metadata.is_dir() {
                EntryKind::Directory
            } else if metadata.is_file() {
                EntryKind::File
            } else {
                EntryKind::Other
            };
            entries.push(SafeEntry {
                name,
                path: entry_path,
                kind,
                reparse_point: is_reparse_point(&metadata),
            });
        }
        entries.sort_by(|left, right| left.name.cmp(&right.name));
        assert_plain_directory(path)?;
        Ok(Self {
            path: path.to_path_buf(),
            entries,
        })
    }

    pub(super) fn directories(&self) -> impl Iterator<Item = &SafeEntry> {
        self.entries
            .iter()
            .filter(|entry| entry.kind == EntryKind::Directory || entry.reparse_point)
    }

    pub(super) fn protocol_file(
        &self,
        expected_name: &str,
        required: bool,
    ) -> Result<Option<Vec<u8>>, String> {
        let matches = self
            .entries
            .iter()
            .filter(|entry| entry.name.eq_ignore_ascii_case(expected_name))
            .collect::<Vec<_>>();
        if matches.len() > 1 {
            return Err(format!(
                "protocol file name collision for '{expected_name}' below '{}'",
                self.path.display()
            ));
        }
        let Some(entry) = matches.first() else {
            return if required {
                Err(format!(
                    "missing required protocol file '{expected_name}' below '{}'",
                    self.path.display()
                ))
            } else {
                Ok(None)
            };
        };
        if entry.name != expected_name {
            return Err(format!(
                "non-canonical protocol file '{}'; expected '{expected_name}'",
                entry.path.display()
            ));
        }
        if entry.kind != EntryKind::File || entry.reparse_point {
            return Err(format!(
                "protocol file must be a plain file: {}",
                entry.path.display()
            ));
        }
        read_bounded_file(&entry.path).map(Some)
    }

    pub(super) fn named_directory(
        &self,
        expected_name: &str,
    ) -> Result<Option<&SafeEntry>, String> {
        let matches = self
            .directories()
            .filter(|entry| entry.name.eq_ignore_ascii_case(expected_name))
            .collect::<Vec<_>>();
        if matches.len() > 1 {
            return Err(format!(
                "directory name collision for '{expected_name}' below '{}'",
                self.path.display()
            ));
        }
        let Some(entry) = matches.first() else {
            return Ok(None);
        };
        if entry.name != expected_name {
            return Err(format!(
                "non-canonical directory '{}'; expected '{expected_name}'",
                entry.path.display()
            ));
        }
        if entry.kind != EntryKind::Directory || entry.reparse_point {
            return Err(format!("directory must be plain: {}", entry.path.display()));
        }
        Ok(Some(entry))
    }
}

fn read_bounded_file(path: &Path) -> Result<Vec<u8>, String> {
    let mut options = OpenOptions::new();
    options.read(true);
    set_open_reparse_point(&mut options);
    let mut file = options
        .open(path)
        .map_err(|error| format!("cannot open protocol file '{}': {error}", path.display()))?;
    let metadata = file
        .metadata()
        .map_err(|error| format!("cannot inspect protocol file '{}': {error}", path.display()))?;
    assert_plain_file(path, &metadata)?;
    if metadata.len() > MAX_PROTOCOL_FILE_BYTES {
        return Err(format!(
            "protocol file '{}' exceeds {MAX_PROTOCOL_FILE_BYTES} bytes",
            path.display()
        ));
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.by_ref()
        .take(MAX_PROTOCOL_FILE_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| format!("cannot read protocol file '{}': {error}", path.display()))?;
    if bytes.len() as u64 != metadata.len() || bytes.len() as u64 > MAX_PROTOCOL_FILE_BYTES {
        return Err(format!(
            "protocol file changed while being read: {}",
            path.display()
        ));
    }
    Ok(bytes)
}

fn assert_plain_directory(path: &Path) -> Result<(), String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("cannot inspect directory '{}': {error}", path.display()))?;
    if !metadata.is_dir() || is_reparse_point(&metadata) {
        return Err(format!("directory must be plain: {}", path.display()));
    }
    Ok(())
}

fn assert_plain_file(path: &Path, metadata: &Metadata) -> Result<(), String> {
    if !metadata.is_file() || is_reparse_point(metadata) {
        return Err(format!("protocol file must be plain: {}", path.display()));
    }
    Ok(())
}

#[cfg(windows)]
fn is_reparse_point(metadata: &Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;

    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0400;
    metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

#[cfg(not(windows))]
fn is_reparse_point(metadata: &Metadata) -> bool {
    metadata.file_type().is_symlink()
}

#[cfg(windows)]
fn set_open_reparse_point(options: &mut OpenOptions) {
    use std::os::windows::fs::OpenOptionsExt;

    const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
    options.custom_flags(FILE_FLAG_OPEN_REPARSE_POINT);
}

#[cfg(not(windows))]
fn set_open_reparse_point(_options: &mut OpenOptions) {}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        path::{Path, PathBuf},
        sync::atomic::{AtomicU64, Ordering},
    };

    use super::DirectorySnapshot;

    #[test]
    fn protocol_files_cannot_be_reparse_points() {
        let fixture = TempDirectory::new();
        let target = fixture.path.join("target.json");
        fs::write(
            &target,
            r#"{"schema":"swawkit.resource/v1","kind":"command"}"#,
        )
        .unwrap();
        let link = fixture.path.join("swawkit.resource.json");
        if let Err(error) = symlink_file(&target, &link) {
            if error.kind() == std::io::ErrorKind::PermissionDenied {
                return;
            }
            panic!("cannot create reparse fixture: {error}");
        }

        let snapshot = DirectorySnapshot::open(&fixture.path).unwrap();
        let error = snapshot
            .protocol_file("swawkit.resource.json", true)
            .unwrap_err();
        assert!(error.contains("plain file"), "{error}");
    }

    #[cfg(windows)]
    fn symlink_file(target: &Path, link: &Path) -> std::io::Result<()> {
        std::os::windows::fs::symlink_file(target, link)
    }

    #[cfg(not(windows))]
    fn symlink_file(target: &Path, link: &Path) -> std::io::Result<()> {
        std::os::unix::fs::symlink(target, link)
    }

    struct TempDirectory {
        path: PathBuf,
    }

    impl TempDirectory {
        fn new() -> Self {
            static NEXT: AtomicU64 = AtomicU64::new(0);
            let sequence = NEXT.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "swawkit-resource-filesystem-{}-{sequence}",
                std::process::id()
            ));
            fs::create_dir_all(&path).unwrap();
            Self { path }
        }
    }

    impl Drop for TempDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }
}
