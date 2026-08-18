use std::fs;
use std::path::{Path, PathBuf};

use swawkit_proj_protocol::{RevisionBuilder, is_revision};

use crate::filesystem::{is_reparse, read_regular_file, regular_directory};

const MAX_FILES: usize = 16_384;
const MAX_ENTRIES: usize = 32_768;
const MAX_FILE_BYTES: u64 = 32 * 1024 * 1024;
const MAX_TOTAL_BYTES: u64 = 256 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct BuildInputSnapshot {
    pub(crate) revision: String,
    pub(crate) file_count: usize,
    pub(crate) total_bytes: u64,
}

pub(crate) fn build_input_snapshot(
    owner_directory: &Path,
    execution_contract_revision: &str,
    nested_owner_directories: &[PathBuf],
) -> Result<BuildInputSnapshot, String> {
    regular_directory(owner_directory, "native owner source directory")?;
    if !is_revision(execution_contract_revision) {
        return Err("execution contract revision is invalid".to_owned());
    }
    let mut files = collect_files(owner_directory, nested_owner_directories)?;
    files.sort_by(|left, right| left.0.cmp(&right.0));
    let mut builder = RevisionBuilder::new("swawkit.native-command-build-input/v1");
    builder.push(
        "executionContractRevision",
        execution_contract_revision.as_bytes(),
    );
    let mut total_bytes = 0_u64;
    for (relative, path) in &files {
        let bytes = read_regular_file(path, "native owner source file", MAX_FILE_BYTES)?;
        total_bytes = total_bytes
            .checked_add(bytes.len() as u64)
            .ok_or_else(|| "native owner source size overflow".to_owned())?;
        if total_bytes > MAX_TOTAL_BYTES {
            return Err(format!(
                "native owner source exceeds {MAX_TOTAL_BYTES} bytes"
            ));
        }
        builder.push("path", relative.as_bytes());
        builder.push("content", &bytes);
    }
    Ok(BuildInputSnapshot {
        revision: builder.finish(),
        file_count: files.len(),
        total_bytes,
    })
}

fn collect_files(
    root: &Path,
    nested_owner_directories: &[PathBuf],
) -> Result<Vec<(String, PathBuf)>, String> {
    let mut files = Vec::new();
    let mut pending = vec![root.to_path_buf()];
    let mut entry_count = 0_usize;
    while let Some(directory) = pending.pop() {
        regular_directory(&directory, "native owner source subtree")?;
        let entries = fs::read_dir(&directory)
            .map_err(|error| format!("cannot enumerate '{}': {error}", directory.display()))?;
        for entry in entries {
            let entry = entry.map_err(|error| {
                format!(
                    "cannot enumerate source below '{}': {error}",
                    directory.display()
                )
            })?;
            entry_count += 1;
            if entry_count > MAX_ENTRIES {
                return Err(format!("native owner source exceeds {MAX_ENTRIES} entries"));
            }
            let path = entry.path();
            let metadata = fs::symlink_metadata(&path)
                .map_err(|error| format!("cannot inspect source '{}': {error}", path.display()))?;
            if is_reparse(&metadata) {
                return Err(format!(
                    "native owner source cannot contain a reparse point: {}",
                    path.display()
                ));
            }
            let name = path
                .file_name()
                .and_then(|name| name.to_str())
                .ok_or_else(|| format!("source path is not Unicode: {}", path.display()))?;
            if metadata.is_dir() {
                let generated_cargo_target = directory == root && name == "target";
                if !generated_cargo_target
                    && !nested_owner_directories
                        .iter()
                        .any(|nested| nested == &path)
                {
                    pending.push(path);
                }
            } else if metadata.is_file() {
                if files.len() == MAX_FILES {
                    return Err(format!("native owner source exceeds {MAX_FILES} files"));
                }
                let relative = path
                    .strip_prefix(root)
                    .map_err(|_| format!("source path escaped owner root: {}", path.display()))?;
                files.push((portable_relative(relative)?, path));
            } else {
                return Err(format!(
                    "native owner source contains an unsupported entry: {}",
                    path.display()
                ));
            }
        }
    }
    Ok(files)
}

fn portable_relative(path: &Path) -> Result<String, String> {
    path.components()
        .map(|component| {
            component
                .as_os_str()
                .to_str()
                .map(str::to_owned)
                .ok_or_else(|| format!("source path is not Unicode: {}", path.display()))
        })
        .collect::<Result<Vec<_>, _>>()
        .map(|segments| segments.join("/"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::filesystem::unique_token;
    use std::io::Write;

    struct Fixture(PathBuf);

    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!("swawkit-snapshot-{}", unique_token()));
            fs::create_dir(&root).unwrap();
            Self(root)
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn snapshot_excludes_generated_target_but_includes_manifest_help_and_source() {
        let fixture = Fixture::new();
        fs::create_dir(fixture.0.join("_src")).unwrap();
        fs::write(fixture.0.join("_src/main.rs"), "fn main() {}\n").unwrap();
        fs::write(fixture.0.join("swawkit.module.json"), r#"{"facets":[]}"#).unwrap();
        fs::create_dir(fixture.0.join("_help")).unwrap();
        fs::write(fixture.0.join("_help/en.txt"), "help").unwrap();
        fs::create_dir(fixture.0.join("target")).unwrap();
        fs::write(fixture.0.join("target/output"), "generated").unwrap();
        fs::create_dir(fixture.0.join("assets")).unwrap();
        fs::create_dir(fixture.0.join("assets/target")).unwrap();
        fs::write(fixture.0.join("assets/target/input"), "resource").unwrap();
        let contract = swawkit_proj_protocol::revision(b"contract");

        let before = build_input_snapshot(&fixture.0, &contract, &[]).unwrap();
        fs::write(fixture.0.join("target/output"), "changed output").unwrap();
        let generated_change = build_input_snapshot(&fixture.0, &contract, &[]).unwrap();
        assert_eq!(before, generated_change);

        fs::write(fixture.0.join("assets/target/input"), "changed resource").unwrap();
        let resource_change = build_input_snapshot(&fixture.0, &contract, &[]).unwrap();
        assert_ne!(generated_change.revision, resource_change.revision);

        fs::write(fixture.0.join("swawkit.module.json"), r#"{"facets":[1]}"#).unwrap();
        let manifest_change = build_input_snapshot(&fixture.0, &contract, &[]).unwrap();
        assert_ne!(resource_change.revision, manifest_change.revision);

        fs::write(fixture.0.join("_help/en.txt"), "changed help").unwrap();
        let help_change = build_input_snapshot(&fixture.0, &contract, &[]).unwrap();
        assert_ne!(manifest_change.revision, help_change.revision);

        let mut source = fs::OpenOptions::new()
            .append(true)
            .open(fixture.0.join("_src/main.rs"))
            .unwrap();
        writeln!(source, "// changed").unwrap();
        let changed = build_input_snapshot(&fixture.0, &contract, &[]).unwrap();
        assert_ne!(help_change.revision, changed.revision);
    }

    #[test]
    fn execution_contract_is_a_synthetic_build_input() {
        let fixture = Fixture::new();
        fs::write(fixture.0.join("Cargo.toml"), "[package]\n").unwrap();
        let first =
            build_input_snapshot(&fixture.0, &swawkit_proj_protocol::revision(b"first"), &[])
                .unwrap();
        let second =
            build_input_snapshot(&fixture.0, &swawkit_proj_protocol::revision(b"second"), &[])
                .unwrap();
        assert_ne!(first.revision, second.revision);
    }

    #[test]
    fn nested_native_owner_sources_are_pruned_from_parent_snapshot() {
        let fixture = Fixture::new();
        let nested = fixture.0.join("child");
        fs::create_dir(&nested).unwrap();
        fs::write(nested.join("main.rs"), "first").unwrap();
        let contract = swawkit_proj_protocol::revision(b"contract");

        let before =
            build_input_snapshot(&fixture.0, &contract, std::slice::from_ref(&nested)).unwrap();
        fs::write(nested.join("main.rs"), "second").unwrap();
        let after = build_input_snapshot(&fixture.0, &contract, &[nested]).unwrap();
        assert_eq!(before, after);
    }
}
