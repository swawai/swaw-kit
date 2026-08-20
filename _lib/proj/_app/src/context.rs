use std::env;
use std::error::Error;
use std::ffi::OsStr;
use std::fmt;
use std::fs;
use std::os::windows::fs::MetadataExt;
use std::path::{Path, PathBuf};

use windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT;

use crate::entry::EntryId;
use crate::launch::LaunchRequest;

/// Entry identity and installation facts after launch transport has been removed.
#[derive(Debug, Clone)]
pub struct EntryContext {
    pub swawkit_home: PathBuf,
    pub data_root: PathBuf,
    /// Runtime storage that owns the product executable for this process.
    ///
    /// This is a running-layout fact, not an Entry-name-derived location.
    pub runtime_root: PathBuf,
    pub entry_file: PathBuf,
    pub entry_name: String,
    pub entry_id: EntryId,
    pub invocation_directory: PathBuf,
    pub product_executable: PathBuf,
    pub release_id: String,
}

impl EntryContext {
    /// Returns whether this process is bound to the one manager Entry.
    ///
    /// Manager authority is a derived layout fact, never a caller supplied
    /// mode bit. Entry lifecycle mutations must check this at their domain
    /// boundary even when their transport already hides the operation.
    pub fn is_manager(&self) -> bool {
        self.entry_name == "swawkit"
            && self.data_root == self.swawkit_home.join("data/proj.swawkit")
            && self.runtime_root == self.data_root.join("runtime")
            && self.entry_file.parent() == Some(self.swawkit_home.as_path())
            && self
                .entry_file
                .file_name()
                .and_then(OsStr::to_str)
                .is_some_and(|name| name.eq_ignore_ascii_case("swawkit.exe"))
    }

    pub fn from_launch(request: &LaunchRequest) -> Result<Self, ContextError> {
        Self::from_product_launch(request, "swawkit-proj.exe")
    }

    pub fn from_host_launch(request: &LaunchRequest) -> Result<Self, ContextError> {
        Self::from_product_launch(request, "swawkit-proj-host.exe")
    }

    fn from_product_launch(
        request: &LaunchRequest,
        executable_name: &str,
    ) -> Result<Self, ContextError> {
        let executable = env::current_exe().map_err(|error| {
            ContextError::new(format!("cannot locate the shared Proj executable: {error}"))
        })?;
        Self::from_sources(request, &executable, executable_name)
    }

    pub fn command_root(&self) -> PathBuf {
        self.swawkit_home.join("_lib").join("proj")
    }

    pub fn system_root(&self) -> PathBuf {
        self.command_root().join("system")
    }

    pub fn swaw_module_root(&self) -> PathBuf {
        self.command_root().join("modules")
    }

    pub fn sibling_product_executable(&self, name: &str) -> PathBuf {
        self.product_executable.with_file_name(name)
    }

    fn from_sources(
        request: &LaunchRequest,
        executable: &Path,
        executable_name: &str,
    ) -> Result<Self, ContextError> {
        let layout = derive_running_layout(executable, executable_name)?;

        let entry_file = absolute_path(&request.entry_file, "project entry file")?;
        if !entry_file.is_file() {
            return Err(ContextError::new(format!(
                "declared project entry file does not exist: {}",
                entry_file.display()
            )));
        }
        if entry_file.parent() != Some(layout.swawkit_home.as_path()) {
            return Err(ContextError::new(format!(
                "the project entry file does not belong to the derived SWAWKIT_HOME '{}': {}",
                layout.swawkit_home.display(),
                entry_file.display()
            )));
        }
        if !entry_file
            .extension()
            .and_then(OsStr::to_str)
            .is_some_and(|extension| extension.eq_ignore_ascii_case("exe"))
        {
            return Err(ContextError::new(format!(
                "the project entry file must have an .exe suffix: {}",
                entry_file.display()
            )));
        }
        let entry_basename = entry_file
            .file_stem()
            .and_then(OsStr::to_str)
            .filter(|name| !name.trim().is_empty())
            .ok_or_else(|| {
                ContextError::new(format!(
                    "the project entry file has no usable Unicode name: {}",
                    entry_file.display()
                ))
            })?
            .to_owned();
        let basename_matches = if layout.entry_name == "swawkit" {
            entry_basename.eq_ignore_ascii_case("swawkit")
        } else {
            entry_basename == layout.entry_name
        };
        if !basename_matches {
            return Err(ContextError::new(format!(
                "the project entry basename '{}' does not match its Runtime DataRoot '{}': {}",
                entry_basename,
                layout.data_root.display(),
                entry_file.display()
            )));
        }

        let disk_entry_id = EntryId::read(&layout.data_root).map_err(|error| {
            ContextError::new(format!(
                "cannot validate the Entry ID in '{}': {error}",
                layout.data_root.display()
            ))
        })?;
        if disk_entry_id != request.entry_id {
            return Err(ContextError::new(format!(
                "the Launcher Entry ID does not match '{}': expected {}, received {}",
                layout.data_root.join("entry.id").display(),
                disk_entry_id,
                request.entry_id
            )));
        }

        let invocation_directory = absolute_path(&request.invocation_dir, "invocation directory")?;
        if !invocation_directory.is_dir() {
            return Err(ContextError::new(format!(
                "invocation directory does not exist: {}",
                invocation_directory.display()
            )));
        }

        Ok(Self {
            swawkit_home: layout.swawkit_home,
            data_root: layout.data_root,
            runtime_root: layout.runtime_root,
            entry_file,
            entry_name: layout.entry_name,
            entry_id: disk_entry_id,
            invocation_directory,
            product_executable: layout.product_executable,
            release_id: layout.release_id,
        })
    }
}

struct RunningLayout {
    swawkit_home: PathBuf,
    data_root: PathBuf,
    runtime_root: PathBuf,
    product_executable: PathBuf,
    entry_name: String,
    release_id: String,
}

fn derive_running_layout(
    executable: &Path,
    executable_name: &str,
) -> Result<RunningLayout, ContextError> {
    let executable = absolute_path(executable, "shared Proj executable")?;
    if executable.file_name() != Some(OsStr::new(executable_name)) {
        return Err(invalid_layout(&executable, executable_name));
    }
    let release_directory = executable
        .parent()
        .ok_or_else(|| invalid_layout(&executable, executable_name))?;
    let release_id = release_directory
        .file_name()
        .and_then(OsStr::to_str)
        .filter(|value| is_release_id(value))
        .ok_or_else(|| invalid_layout(&executable, executable_name))?;
    debug_assert_eq!(release_id.len(), 64);
    let releases_directory = expected_parent(release_directory, "releases", executable_name)?;
    let runtime_directory = expected_parent(releases_directory, "runtime", executable_name)?;
    let data_root = runtime_directory
        .parent()
        .ok_or_else(|| invalid_layout(&executable, executable_name))?;
    let data_root_name = data_root
        .file_name()
        .and_then(OsStr::to_str)
        .ok_or_else(|| invalid_layout(&executable, executable_name))?;
    let entry_name = data_root_name
        .strip_prefix("proj.")
        .filter(|name| !name.is_empty())
        .ok_or_else(|| invalid_layout(&executable, executable_name))?;
    let data_directory = expected_parent(data_root, "data", executable_name)?;
    let swawkit_home = data_directory
        .parent()
        .ok_or_else(|| invalid_layout(&executable, executable_name))?;
    if !swawkit_home.is_dir() {
        return Err(ContextError::new(format!(
            "derived SWAWKIT_HOME does not exist: {}",
            swawkit_home.display()
        )));
    }
    for (path, label) in [
        (swawkit_home, "SWAWKIT_HOME"),
        (data_directory, "Proj data directory"),
        (data_root, "Entry DataRoot"),
        (runtime_directory, "Entry Runtime directory"),
        (releases_directory, "Runtime releases directory"),
        (release_directory, "Runtime Release directory"),
    ] {
        validate_regular_directory(path, label)?;
    }
    Ok(RunningLayout {
        swawkit_home: swawkit_home.to_path_buf(),
        data_root: data_root.to_path_buf(),
        runtime_root: runtime_directory.to_path_buf(),
        product_executable: executable.clone(),
        entry_name: entry_name.to_owned(),
        release_id: release_id.to_owned(),
    })
}

fn expected_parent<'a>(
    path: &'a Path,
    name: &str,
    executable_name: &str,
) -> Result<&'a Path, ContextError> {
    let parent = path
        .parent()
        .ok_or_else(|| invalid_layout(path, executable_name))?;
    if parent.file_name() != Some(OsStr::new(name)) {
        return Err(invalid_layout(path, executable_name));
    }
    Ok(parent)
}

fn invalid_layout(path: &Path, executable_name: &str) -> ContextError {
    ContextError::new(format!(
        "shared Proj executable must belong to 'data\\proj.<entry>\\runtime\\releases\\<release-id>\\{executable_name}': {}",
        path.display()
    ))
}

fn validate_regular_directory(path: &Path, label: &str) -> Result<(), ContextError> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        ContextError::new(format!(
            "cannot inspect {label} '{}': {error}",
            path.display()
        ))
    })?;
    if !metadata.is_dir() || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(ContextError::new(format!(
            "{label} must be a regular non-reparse directory: {}",
            path.display()
        )));
    }
    Ok(())
}

fn is_release_id(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn absolute_path(path: &Path, label: &str) -> Result<PathBuf, ContextError> {
    let absolute = std::path::absolute(path).map_err(|error| {
        ContextError::new(format!(
            "invalid {label} path '{}': {error}",
            path.display()
        ))
    })?;
    crate::windows_path::dos_absolute(&absolute).map_err(|reason| {
        ContextError::new(format!(
            "invalid {label} path '{}': {reason}",
            path.display()
        ))
    })
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContextError {
    message: String,
}

impl ContextError {
    fn new(message: String) -> Self {
        Self { message }
    }
}

impl fmt::Display for ContextError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl Error for ContextError {}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::launch::LaunchMode;
    use std::ffi::OsString;
    use std::fs;
    use std::os::windows::ffi::{OsStrExt, OsStringExt};
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);
    const TEST_ENTRY_ID: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    struct Fixture {
        root: PathBuf,
        data_root: PathBuf,
        executable: PathBuf,
        entry_file: PathBuf,
        invocation_dir: PathBuf,
    }

    impl Fixture {
        fn new() -> Self {
            Self::new_named("project-one.exe", "proj.project-one")
        }

        fn new_named(entry_file_name: &str, data_root_name: &str) -> Self {
            let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
            let root =
                env::temp_dir().join(format!("swawkit-context-{}-{sequence}", std::process::id()));
            let data_root = root.join("data").join(data_root_name);
            let executable = data_root
                .join("runtime/releases")
                .join("a".repeat(64))
                .join("swawkit-proj.exe");
            let entry_file = root.join(entry_file_name);
            let invocation_dir = root.join("work");
            for directory in [
                executable.parent().expect("executable parent"),
                entry_file.parent().expect("entry parent"),
                &invocation_dir,
            ] {
                fs::create_dir_all(directory).expect("create fixture directory");
            }
            fs::write(&executable, "fixture").expect("write executable");
            fs::write(&entry_file, "fixture").expect("write entry file");
            fs::write(data_root.join("entry.id"), format!("{TEST_ENTRY_ID}\n"))
                .expect("write Entry ID");

            Self {
                root,
                data_root,
                executable,
                entry_file,
                invocation_dir,
            }
        }

        fn request(&self) -> LaunchRequest {
            LaunchRequest {
                mode: LaunchMode::Cli,
                entry_file: self.entry_file.clone(),
                entry_id: EntryId::parse(TEST_ENTRY_ID).expect("test Entry ID"),
                invocation_dir: self.invocation_dir.clone(),
                argv: Vec::new(),
            }
        }

        fn context(&self) -> Result<EntryContext, ContextError> {
            EntryContext::from_sources(&self.request(), &self.executable, "swawkit-proj.exe")
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    #[test]
    fn derives_owned_identity_instead_of_trusting_spoofable_names() {
        let fixture = Fixture::new();
        let context = fixture.context().expect("entry context");

        assert_eq!(context.swawkit_home, fixture.root);
        assert_eq!(context.data_root, fixture.data_root);
        assert_eq!(context.runtime_root, fixture.data_root.join("runtime"));
        assert_eq!(context.entry_name, "project-one");
        assert_eq!(context.entry_id.as_str(), TEST_ENTRY_ID);
        assert_eq!(context.entry_file, fixture.entry_file);
        assert_eq!(context.invocation_directory, fixture.invocation_dir);
        assert_eq!(context.release_id, "a".repeat(64));
    }

    #[test]
    fn normalizes_verbatim_process_paths_before_building_domain_context() {
        let fixture = Fixture::new();
        let mut request = fixture.request();
        request.entry_file = verbatim_disk(&fixture.entry_file);
        request.invocation_dir = verbatim_disk(&fixture.invocation_dir);
        let executable = verbatim_disk(&fixture.executable);

        let context = EntryContext::from_sources(&request, &executable, "swawkit-proj.exe")
            .expect("normalize verbatim launch paths");

        assert_eq!(context.swawkit_home, fixture.root);
        assert_eq!(context.entry_file, fixture.entry_file);
        assert_eq!(context.data_root, fixture.data_root);
        assert_eq!(context.runtime_root, fixture.data_root.join("runtime"));
        assert_eq!(context.product_executable, fixture.executable);
        assert_eq!(context.invocation_directory, fixture.invocation_dir);
    }

    #[test]
    fn canonicalizes_the_ascii_case_insensitive_manager_basename() {
        let fixture = Fixture::new_named("SwAwKiT.exe", "proj.swawkit");
        let context = fixture.context().expect("manager Entry context");

        assert_eq!(context.entry_name, "swawkit");
        assert_eq!(context.data_root, fixture.root.join("data/proj.swawkit"));
    }

    #[test]
    fn explicitly_rejects_the_legacy_shared_bin_layout() {
        let fixture = Fixture::new();
        let legacy = fixture.root.join(format!(
            "_lib/proj/_bin/releases/{}/swawkit-proj.exe",
            "a".repeat(64)
        ));
        fs::create_dir_all(legacy.parent().unwrap()).expect("create legacy layout");
        fs::write(&legacy, "legacy").expect("write legacy executable");
        let error = EntryContext::from_sources(&fixture.request(), &legacy, "swawkit-proj.exe")
            .expect_err("legacy shared Runtime layout must fail closed");

        assert!(error.to_string().contains("data\\proj.<entry>\\runtime"));
    }

    #[test]
    fn rejects_an_entry_basename_that_does_not_own_the_runtime() {
        let fixture = Fixture::new();
        let other_entry = fixture.root.join("other.exe");
        fs::write(&other_entry, "fixture").expect("write other Entry");
        let mut request = fixture.request();
        request.entry_file = other_entry;

        let error = EntryContext::from_sources(&request, &fixture.executable, "swawkit-proj.exe")
            .expect_err("mismatched Entry basename must fail closed");
        assert!(
            error
                .to_string()
                .contains("does not match its Runtime DataRoot")
        );
    }

    #[test]
    fn rejects_a_launcher_entry_id_that_does_not_match_disk() {
        let fixture = Fixture::new();
        let mut request = fixture.request();
        request.entry_id = EntryId::parse(&"b".repeat(64)).expect("other Entry ID");

        let error = EntryContext::from_sources(&request, &fixture.executable, "swawkit-proj.exe")
            .expect_err("mismatched Launcher Entry ID must fail closed");
        assert!(
            error
                .to_string()
                .contains("Launcher Entry ID does not match")
        );
    }

    #[test]
    fn rejects_a_runtime_reparse_ancestor() {
        let fixture = Fixture::new();
        let runtime = fixture.data_root.join("runtime");
        let external = fixture.root.join("external-runtime");
        fs::rename(&runtime, &external).expect("move Runtime fixture");
        if let Err(error) = std::os::windows::fs::symlink_dir(&external, &runtime) {
            eprintln!("skipping Runtime reparse test: {error}");
            fs::rename(&external, &runtime).expect("restore Runtime fixture");
            return;
        }

        let error = fixture
            .context()
            .expect_err("a Runtime reparse ancestor must fail closed");
        assert!(error.to_string().contains("regular non-reparse directory"));
        fs::remove_dir(runtime).expect("remove Runtime reparse point");
    }

    fn verbatim_disk(path: &Path) -> PathBuf {
        let units = path.as_os_str().encode_wide().collect::<Vec<_>>();
        assert!(units.len() >= 3 && units[1] == b':' as u16 && units[2] == b'\\' as u16);
        let mut verbatim = vec![b'\\' as u16, b'\\' as u16, b'?' as u16, b'\\' as u16];
        verbatim.extend_from_slice(&units);
        PathBuf::from(OsString::from_wide(&verbatim))
    }

    #[test]
    fn validates_owned_filesystem_facts_without_project_declarations() {
        let fixture = Fixture::new();
        fs::remove_file(&fixture.entry_file).expect("remove entry fixture");
        assert!(
            fixture
                .context()
                .unwrap_err()
                .to_string()
                .contains("entry file does not exist")
        );
    }
}
