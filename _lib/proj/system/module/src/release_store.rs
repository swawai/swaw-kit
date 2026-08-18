use std::fs;
use std::path::{Path, PathBuf};

use swawkit_proj_protocol::{
    COMMAND_EXECUTABLE_NAME, CommandIdentity, CommandRelease, command_release_document,
    command_release_id, is_sha256, native_command_root, parse_command_release,
    validate_command_artifact, validate_command_release,
};

use crate::filesystem::{
    atomic_replace, checked_directory, ensure_directory, entry_exists, is_reparse,
    read_regular_file, regular_directory, remove_tree, unique_token, write_new,
};

const RELEASE_FILE: &str = "swawkit.release.json";
const MAX_RELEASE_BYTES: u64 = 1024 * 1024;
const MAX_EXECUTABLE_BYTES: u64 = 512 * 1024 * 1024;

pub(crate) struct Publication {
    pub(crate) release_id: String,
    pub(crate) changed: bool,
}

pub(crate) struct SelectedRelease {
    pub(crate) release_id: String,
    pub(crate) manifest: CommandRelease,
}

pub(crate) fn prepare_native_root(
    data_root: &Path,
    owner: &CommandIdentity,
) -> Result<PathBuf, String> {
    regular_directory(data_root, "Entry DataRoot")?;
    let segments = native_root_segments(data_root, owner)?;
    ensure_directory(data_root, segments, "native command DataRoot")
}

pub(crate) fn read_selected_from_data_root(
    data_root: &Path,
    expected_owner: &CommandIdentity,
) -> Result<Option<SelectedRelease>, String> {
    regular_directory(data_root, "Entry DataRoot")?;
    let mut current = data_root.to_path_buf();
    for segment in native_root_segments(data_root, expected_owner)? {
        current.push(segment);
        if !entry_exists(&current, "native command DataRoot")? {
            return Ok(None);
        }
        regular_directory(&current, "native command DataRoot")?;
    }
    read_selected(&current, &expected_owner.address())
}

fn native_root_segments(data_root: &Path, owner: &CommandIdentity) -> Result<Vec<String>, String> {
    native_command_root(data_root, owner)
        .strip_prefix(data_root)
        .map_err(|_| "native command DataRoot escaped Entry DataRoot".to_owned())?
        .components()
        .map(|component| {
            component
                .as_os_str()
                .to_str()
                .map(str::to_owned)
                .ok_or_else(|| "native command DataRoot is not Unicode".to_owned())
        })
        .collect()
}

pub(crate) fn publish(
    native_root: &Path,
    release: &CommandRelease,
    executable: &[u8],
) -> Result<Publication, String> {
    validate_command_release(release, &release.owner).map_err(|error| error.to_string())?;
    validate_command_artifact(release, executable).map_err(|error| error.to_string())?;
    let document = command_release_document(release).map_err(|error| error.to_string())?;
    let release_id = command_release_id(&document);
    let capability = ensure_directory(native_root, ["export", "command"], "native command export")?;
    let releases = ensure_directory(&capability, ["releases"], "native command releases")?;
    let target = releases.join(&release_id);
    if entry_exists(&target, "native command release")? {
        validate_release_directory(&target, &release_id, &release.owner)?;
    } else {
        publish_release_directory(&releases, &target, &document, executable)?;
        validate_release_directory(&target, &release_id, &release.owner)?;
    }
    let selector = capability.join("current");
    let selection = format!("{release_id}\n");
    let changed = read_optional_selector(&selector)?.as_deref() != Some(release_id.as_str());
    if changed {
        atomic_replace(&selector, selection.as_bytes(), "native command selector")?;
    }
    Ok(Publication {
        release_id,
        changed,
    })
}

pub(crate) fn read_selected(
    native_root: &Path,
    expected_owner: &str,
) -> Result<Option<SelectedRelease>, String> {
    if !entry_exists(native_root, "native command runtime")? {
        return Ok(None);
    }
    regular_directory(native_root, "native command runtime")?;
    let export =
        match checked_directory(native_root, ["export", "command"], "native command export") {
            Ok(path) => path,
            Err(_error)
                if !entry_exists(&native_root.join("export/command"), "native command export")? =>
            {
                return Ok(None);
            }
            Err(error) => return Err(error),
        };
    let selector = export.join("current");
    let Some(release_id) = read_optional_selector(&selector)? else {
        return Ok(None);
    };
    let releases = checked_directory(&export, ["releases"], "native command releases")?;
    let release_root = checked_directory(
        &releases,
        [release_id.as_str()],
        "selected native command release",
    )?;
    let manifest = validate_release_directory(&release_root, &release_id, expected_owner)?;
    Ok(Some(SelectedRelease {
        release_id,
        manifest,
    }))
}

fn publish_release_directory(
    releases: &Path,
    target: &Path,
    document: &[u8],
    executable: &[u8],
) -> Result<(), String> {
    let stage = releases.join(format!(".release.{}.tmp", unique_token()));
    fs::create_dir(&stage).map_err(|error| {
        format!(
            "cannot create staged native command release '{}': {error}",
            stage.display()
        )
    })?;
    let mut committed = false;
    let result = (|| {
        regular_directory(&stage, "staged native command release")?;
        write_new(
            &stage.join(COMMAND_EXECUTABLE_NAME),
            executable,
            "staged command executable",
        )?;
        write_new(
            &stage.join(RELEASE_FILE),
            document,
            "staged command release document",
        )?;
        match fs::rename(&stage, target) {
            Ok(()) => {
                committed = true;
                Ok(())
            }
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::AlreadyExists | std::io::ErrorKind::PermissionDenied
                ) && entry_exists(target, "native command release")? =>
            {
                Ok(())
            }
            Err(error) => Err(format!(
                "cannot publish native command release '{}': {error}",
                target.display()
            )),
        }
    })();
    if !committed {
        remove_tree(&stage);
    }
    result
}

fn validate_release_directory(
    root: &Path,
    expected_id: &str,
    expected_owner: &str,
) -> Result<CommandRelease, String> {
    if !is_sha256(expected_id) {
        return Err("selected native command Release ID is invalid".to_owned());
    }
    regular_directory(root, "native command release")?;
    let entries = fs::read_dir(root)
        .map_err(|error| format!("cannot enumerate release '{}': {error}", root.display()))?;
    let mut members = Vec::with_capacity(2);
    for entry in entries {
        let entry = entry
            .map_err(|error| format!("cannot enumerate release '{}': {error}", root.display()))?;
        if members.len() == 2 {
            return Err(format!(
                "native command release has invalid membership: {}",
                root.display()
            ));
        }
        let metadata = fs::symlink_metadata(entry.path()).map_err(|error| {
            format!(
                "cannot inspect release member '{}': {error}",
                entry.path().display()
            )
        })?;
        if !metadata.is_file() || is_reparse(&metadata) {
            return Err(format!(
                "native command release has an unsafe member: {}",
                entry.path().display()
            ));
        }
        members.push(
            entry
                .file_name()
                .into_string()
                .map_err(|_| "native command release member is not Unicode".to_owned())?,
        );
    }
    members.sort();
    if members != [COMMAND_EXECUTABLE_NAME, RELEASE_FILE] {
        return Err(format!(
            "native command release has invalid membership: {}",
            root.display()
        ));
    }
    let document = read_regular_file(
        &root.join(RELEASE_FILE),
        "native command release document",
        MAX_RELEASE_BYTES,
    )?;
    if command_release_id(&document) != expected_id {
        return Err(format!(
            "native command release document does not match Release ID '{expected_id}'"
        ));
    }
    let manifest = parse_command_release(&document).map_err(|error| error.to_string())?;
    validate_command_release(&manifest, expected_owner).map_err(|error| error.to_string())?;
    let executable = read_regular_file(
        &root.join(COMMAND_EXECUTABLE_NAME),
        "native command executable",
        MAX_EXECUTABLE_BYTES,
    )?;
    validate_command_artifact(&manifest, &executable).map_err(|error| error.to_string())?;
    Ok(manifest)
}

fn read_optional_selector(path: &Path) -> Result<Option<String>, String> {
    if !entry_exists(path, "native command selector")? {
        return Ok(None);
    }
    let bytes = read_regular_file(path, "native command selector", 65)?;
    if bytes.len() != 65 || bytes.last() != Some(&b'\n') {
        return Err(
            "native command selector must contain exactly one lowercase SHA-256 digest followed by LF"
                .to_owned(),
        );
    }
    let text = std::str::from_utf8(&bytes[..64])
        .map_err(|error| format!("native command selector is not UTF-8: {error}"))?;
    if !is_sha256(text) {
        return Err("native command selector is invalid".to_owned());
    }
    Ok(Some(text.to_owned()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::filesystem::unique_token;
    use swawkit_proj_protocol::{CommandIdentity, CommandRelease, revision};

    struct Fixture(PathBuf);

    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!("swawkit-release-{}", unique_token()));
            fs::create_dir(&root).unwrap();
            Self(root)
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn release(bytes: &[u8]) -> CommandRelease {
        CommandRelease::new(
            "swaw/context",
            revision(b"build"),
            revision(b"contract"),
            vec!["swaw/context/show".to_owned()],
            bytes,
        )
        .unwrap()
    }

    #[test]
    fn publication_is_immutable_and_idempotent() {
        let fixture = Fixture::new();
        let native = ensure_directory(&fixture.0, ["native"], "fixture").unwrap();
        let first = publish(&native, &release(b"executable"), b"executable").unwrap();
        let second = publish(&native, &release(b"executable"), b"executable").unwrap();
        assert!(first.changed);
        assert!(!second.changed);
        assert_eq!(first.release_id, second.release_id);
        let selected = read_selected(&native, "swaw/context").unwrap().unwrap();
        assert_eq!(selected.release_id, first.release_id);
    }

    #[test]
    fn switching_back_to_an_existing_release_reports_a_selector_change() {
        let fixture = Fixture::new();
        let native = ensure_directory(&fixture.0, ["native"], "fixture").unwrap();
        let first = publish(&native, &release(b"first"), b"first").unwrap();
        let second = publish(&native, &release(b"second"), b"second").unwrap();
        assert!(second.changed);
        let returned = publish(&native, &release(b"first"), b"first").unwrap();
        assert!(returned.changed);
        assert_eq!(returned.release_id, first.release_id);
    }

    #[test]
    fn selected_v2_release_is_rejected() {
        let fixture = Fixture::new();
        let native = ensure_directory(&fixture.0, ["native"], "fixture").unwrap();
        let publication = publish(&native, &release(b"executable"), b"executable").unwrap();
        let releases = native.join("export/command/releases");
        let release_root = releases.join(publication.release_id);
        let path = release_root.join(RELEASE_FILE);
        let mut value: swawkit_proj_protocol::serde_json::Value =
            swawkit_proj_protocol::serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        value["schema"] = "swawkit.native-command-release/v2".into();
        let document = swawkit_proj_protocol::serde_json::to_vec(&value).unwrap();
        let old_id = command_release_id(&document);
        fs::write(&path, document).unwrap();
        fs::rename(release_root, releases.join(&old_id)).unwrap();
        fs::write(native.join("export/command/current"), format!("{old_id}\n")).unwrap();
        let error = read_selected(&native, "swaw/context").err().unwrap();
        assert!(
            error.contains("unsupported command release schema"),
            "{error}"
        );
    }

    #[test]
    fn native_data_roots_are_structured_by_command_space() {
        let fixture = Fixture::new();
        let system = CommandIdentity::parse(".context").unwrap();
        let module = CommandIdentity::parse("swaw/context").unwrap();

        assert_eq!(
            prepare_native_root(&fixture.0, &system).unwrap(),
            fixture.0.join("modules/system/context/_native")
        );
        assert_eq!(
            prepare_native_root(&fixture.0, &module).unwrap(),
            fixture.0.join("modules/swaw/context/_native")
        );
    }

    #[test]
    fn selector_without_lf_is_rejected() {
        let fixture = Fixture::new();
        let native = ensure_directory(&fixture.0, ["native"], "fixture").unwrap();
        publish(&native, &release(b"executable"), b"executable").unwrap();
        let selector = native.join("export/command/current");
        let bytes = fs::read(&selector).unwrap();
        fs::write(&selector, &bytes[..bytes.len() - 1]).unwrap();
        let error = read_selected(&native, "swaw/context").err().unwrap();
        assert!(error.contains("followed by LF"), "{error}");
    }
}
