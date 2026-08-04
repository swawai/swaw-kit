use std::env;
use std::error::Error;
use std::ffi::{OsStr, OsString};
use std::fmt;
use std::path::{Path, PathBuf};

use crate::launch::LaunchRequest;

const PROTOCOL_ENV: &str = "SWAWKIT_PROJ_PROTOCOL";
const PROJECT_ROOT_ENV: &str = "SWAWKIT_PROJ_DIR";
const ACTION_ROOT_ENV: &str = "SWAWKIT_PROJ_ACTION_ROOT";

/// Project identity and filesystem facts after launch transport has been removed.
#[derive(Debug, Clone)]
pub struct EntryContext {
    pub proj_home: PathBuf,
    pub project_root: PathBuf,
    pub action_root: PathBuf,
    pub entry_file: PathBuf,
    pub entry_name: String,
    pub invocation_directory: PathBuf,
}

impl EntryContext {
    pub fn from_launch(request: &LaunchRequest) -> Result<Self, ContextError> {
        let executable = env::current_exe().map_err(|error| {
            ContextError::new(format!("cannot locate the shared Proj executable: {error}"))
        })?;
        Self::from_sources(request, &executable, |name| env::var_os(name))
    }

    pub fn kernel_root(&self) -> PathBuf {
        self.proj_home.join("_lib").join("proj")
    }

    fn from_sources(
        request: &LaunchRequest,
        executable: &Path,
        mut lookup: impl FnMut(&str) -> Option<OsString>,
    ) -> Result<Self, ContextError> {
        let protocol = required_text(&mut lookup, PROTOCOL_ENV)?;
        if protocol != "1" {
            return Err(ContextError::new(format!(
                "unsupported {PROTOCOL_ENV} value '{protocol}'; expected '1'"
            )));
        }

        let proj_home = derive_proj_home(executable)?;
        let project_root = required_path(&mut lookup, PROJECT_ROOT_ENV)?;
        if !project_root.is_dir() {
            return Err(ContextError::new(format!(
                "declared project directory does not exist: {}",
                project_root.display()
            )));
        }
        let action_root = required_path(&mut lookup, ACTION_ROOT_ENV)?;

        let entry_file = absolute_path(&request.entry_file, "project entry file")?;
        if !entry_file.is_file() {
            return Err(ContextError::new(format!(
                "declared project entry file does not exist: {}",
                entry_file.display()
            )));
        }
        let entry_name = entry_file
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

        let invocation_directory = absolute_path(&request.invocation_dir, "invocation directory")?;
        if !invocation_directory.is_dir() {
            return Err(ContextError::new(format!(
                "invocation directory does not exist: {}",
                invocation_directory.display()
            )));
        }

        Ok(Self {
            proj_home,
            project_root,
            action_root,
            entry_file,
            entry_name,
            invocation_directory,
        })
    }
}

fn derive_proj_home(executable: &Path) -> Result<PathBuf, ContextError> {
    let executable = absolute_path(executable, "shared Proj executable")?;
    if executable.file_name() != Some(OsStr::new("swawkit-proj.exe")) {
        return Err(invalid_layout(&executable));
    }
    let runtime_directory = expected_parent(&executable, "_bin")?;
    let kernel_root = expected_parent(runtime_directory, "proj")?;
    let library_root = expected_parent(kernel_root, "_lib")?;
    let proj_home = library_root
        .parent()
        .ok_or_else(|| invalid_layout(&executable))?;
    if !proj_home.is_dir() {
        return Err(ContextError::new(format!(
            "derived Swaw Kit Proj home does not exist: {}",
            proj_home.display()
        )));
    }
    Ok(proj_home.to_path_buf())
}

fn expected_parent<'a>(path: &'a Path, name: &str) -> Result<&'a Path, ContextError> {
    let parent = path.parent().ok_or_else(|| invalid_layout(path))?;
    if parent.file_name() != Some(OsStr::new(name)) {
        return Err(invalid_layout(path));
    }
    Ok(parent)
}

fn invalid_layout(path: &Path) -> ContextError {
    ContextError::new(format!(
        "shared Proj executable must be published as '_lib\\proj\\_bin\\swawkit-proj.exe': {}",
        path.display()
    ))
}

fn required_text(
    lookup: &mut impl FnMut(&str) -> Option<OsString>,
    name: &'static str,
) -> Result<String, ContextError> {
    let value = lookup(name).ok_or_else(|| missing_declaration(name))?;
    let value = value.into_string().map_err(|_| {
        ContextError::new(format!("project declaration {name} is not valid Unicode"))
    })?;
    if value.trim().is_empty() {
        return Err(missing_declaration(name));
    }
    Ok(value)
}

fn required_path(
    lookup: &mut impl FnMut(&str) -> Option<OsString>,
    name: &'static str,
) -> Result<PathBuf, ContextError> {
    let value = lookup(name).ok_or_else(|| missing_declaration(name))?;
    if value.is_empty() {
        return Err(missing_declaration(name));
    }
    let path = PathBuf::from(value);
    if !path.is_absolute() {
        return Err(ContextError::new(format!(
            "project path declaration {name} must be absolute: {}",
            path.display()
        )));
    }
    absolute_path(&path, name)
}

fn absolute_path(path: &Path, label: &str) -> Result<PathBuf, ContextError> {
    std::path::absolute(path).map_err(|error| {
        ContextError::new(format!(
            "invalid {label} path '{}': {error}",
            path.display()
        ))
    })
}

fn missing_declaration(name: &'static str) -> ContextError {
    ContextError::new(format!("required project declaration is missing: {name}"))
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
    use std::collections::HashMap;
    use std::fs;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

    struct Fixture {
        root: PathBuf,
        executable: PathBuf,
        entry_file: PathBuf,
        invocation_dir: PathBuf,
        declarations: HashMap<String, OsString>,
    }

    impl Fixture {
        fn new() -> Self {
            let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
            let root =
                env::temp_dir().join(format!("swawkit-context-{}-{sequence}", std::process::id()));
            let executable = root.join("_lib/proj/_bin/swawkit-proj.exe");
            let entry_file = root.join("Favorites/project-one.exe");
            let invocation_dir = root.join("work");
            let project_root = root.join("project");
            let action_root = project_root.join(".swaw");
            for directory in [
                executable.parent().expect("executable parent"),
                entry_file.parent().expect("entry parent"),
                &invocation_dir,
                &project_root,
            ] {
                fs::create_dir_all(directory).expect("create fixture directory");
            }
            fs::write(&executable, "fixture").expect("write executable");
            fs::write(&entry_file, "fixture").expect("write entry file");

            let declarations = HashMap::from([
                (PROTOCOL_ENV.to_owned(), OsString::from("1")),
                (
                    PROJECT_ROOT_ENV.to_owned(),
                    project_root.as_os_str().to_owned(),
                ),
                (
                    ACTION_ROOT_ENV.to_owned(),
                    action_root.as_os_str().to_owned(),
                ),
                (
                    "SWAWKIT_PROJ_ENTRY_COMMAND".to_owned(),
                    OsString::from("spoofed-name"),
                ),
                (
                    "SWAWKIT_PROJ_HOME".to_owned(),
                    OsString::from(r"C:\spoofed-home"),
                ),
            ]);

            Self {
                root,
                executable,
                entry_file,
                invocation_dir,
                declarations,
            }
        }

        fn request(&self) -> LaunchRequest {
            LaunchRequest {
                mode: LaunchMode::Cli,
                entry_file: self.entry_file.clone(),
                invocation_dir: self.invocation_dir.clone(),
                argv: Vec::new(),
            }
        }

        fn context(&self) -> Result<EntryContext, ContextError> {
            EntryContext::from_sources(&self.request(), &self.executable, |name| {
                self.declarations.get(name).cloned()
            })
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

        assert_eq!(context.proj_home, fixture.root);
        assert_eq!(context.entry_name, "project-one");
        assert_eq!(context.entry_file, fixture.entry_file);
        assert_eq!(context.invocation_directory, fixture.invocation_dir);
    }

    #[test]
    fn rejects_an_executable_outside_the_shared_runtime_layout() {
        let fixture = Fixture::new();
        let misplaced = fixture.root.join("swawkit-proj.exe");
        let error = EntryContext::from_sources(&fixture.request(), &misplaced, |name| {
            fixture.declarations.get(name).cloned()
        })
        .unwrap_err();

        assert!(error.to_string().contains("_lib\\proj\\_bin"));
    }

    #[test]
    fn validates_protocol_and_owned_filesystem_facts() {
        let mut fixture = Fixture::new();
        fixture.declarations.remove(PROTOCOL_ENV);
        assert!(
            fixture
                .context()
                .unwrap_err()
                .to_string()
                .contains(PROTOCOL_ENV)
        );

        fixture
            .declarations
            .insert(PROTOCOL_ENV.to_owned(), OsString::from("1"));
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
