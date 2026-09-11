use std::fs;
use std::io::Read;
use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Component, Path};

use serde_json::Value;
use windows_sys::Win32::Storage::FileSystem::{
    FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_OPEN_REPARSE_POINT,
};

use crate::catalog::CommandNode;
use crate::command::catalog_command_data_root_from_roots;

const PROVIDER_STATE_SCHEMA: &str = "swawkit.command-provider-state/v3";
const MAX_PROVIDER_STATE_BYTES: u64 = 64 * 1024;
const REVISION_PREFIX: &str = "sha256-";

pub(super) struct PublicationEvaluation {
    pub ready: bool,
    pub status: String,
    pub message: Option<String>,
}

pub(super) fn inspect_publication(
    data_root: &Path,
    entry_name: &str,
    provider: &CommandNode,
) -> PublicationEvaluation {
    let module_root = match catalog_command_data_root_from_roots(data_root, provider) {
        Ok(path) => path,
        Err(error) => {
            return publication_failure("data-root-unavailable", error.to_string());
        }
    };
    if let Err(error) = validate_provider_directory_chain(data_root, &module_root) {
        return publication_failure("provider-path-invalid", error);
    }
    inspect_publication_root(&module_root, entry_name, provider)
}

fn inspect_publication_root(
    module_root: &Path,
    entry_name: &str,
    provider: &CommandNode,
) -> PublicationEvaluation {
    let state_path = module_root.join("_state.json");
    let export_root = module_root.join("export");
    let export_ready = match inspect_export_root(&export_root) {
        Ok(ready) => ready,
        Err(error) => {
            return PublicationEvaluation {
                ready: false,
                status: "export-invalid".to_owned(),
                message: Some(error),
            };
        }
    };
    let state = match read_provider_state(&state_path) {
        Ok(state) => state,
        Err(error) => {
            return PublicationEvaluation {
                ready: false,
                status: "state-invalid".to_owned(),
                message: Some(error),
            };
        }
    };
    let Some(state) = state else {
        return PublicationEvaluation {
            ready: false,
            status: "state-missing".to_owned(),
            message: Some(format!("run '{entry_name} {}'", provider.address)),
        };
    };
    let status = state
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or("invalid");
    let ready = status == "ready" && export_ready;
    let message = if status != "ready" {
        Some(format!(
            "provider state is {status}; run '{} {}'",
            entry_name, provider.address
        ))
    } else if !export_ready {
        Some("provider export directory is missing or unsafe".to_owned())
    } else {
        None
    };
    PublicationEvaluation {
        ready,
        status: if ready { "ready" } else { "not-ready" }.to_owned(),
        message,
    }
}

fn publication_failure(status: &str, message: String) -> PublicationEvaluation {
    PublicationEvaluation {
        ready: false,
        status: status.to_owned(),
        message: Some(message),
    }
}

fn read_provider_state(path: &Path) -> Result<Option<Value>, String> {
    let content = match read_provider_state_bytes(path, |_| Ok(()))? {
        Some(content) => content,
        None => return Ok(None),
    };
    let value: Value = serde_json::from_slice(&content)
        .map_err(|error| format!("cannot parse provider state '{}': {error}", path.display()))?;
    validate_provider_state(&value)
        .map_err(|error| format!("provider state '{}' is invalid: {error}", path.display()))?;
    Ok(Some(value))
}

fn read_provider_state_bytes(
    path: &Path,
    before_read: impl FnOnce(&Path) -> std::io::Result<()>,
) -> Result<Option<Vec<u8>>, String> {
    let mut file = match fs::OpenOptions::new()
        .read(true)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(format!(
                "cannot open provider state '{}': {error}",
                path.display()
            ));
        }
    };
    let metadata = file.metadata().map_err(|error| {
        format!(
            "cannot inspect provider state '{}': {error}",
            path.display()
        )
    })?;
    if !metadata.is_file()
        || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
        || metadata.len() > MAX_PROVIDER_STATE_BYTES
    {
        return Err(format!(
            "provider state is not a bounded regular file: {}",
            path.display()
        ));
    }
    let initial_length = metadata.len();
    before_read(path).map_err(|error| {
        format!(
            "cannot prepare provider state read '{}': {error}",
            path.display()
        )
    })?;
    let mut content = Vec::with_capacity(initial_length as usize);
    file.by_ref()
        .take(MAX_PROVIDER_STATE_BYTES + 1)
        .read_to_end(&mut content)
        .map_err(|error| format!("cannot read provider state '{}': {error}", path.display()))?;
    if content.len() as u64 > MAX_PROVIDER_STATE_BYTES {
        return Err(format!(
            "provider state exceeds its {MAX_PROVIDER_STATE_BYTES}-byte limit while being read: {}",
            path.display()
        ));
    }
    let final_metadata = file.metadata().map_err(|error| {
        format!(
            "cannot re-inspect provider state '{}': {error}",
            path.display()
        )
    })?;
    if !final_metadata.is_file()
        || final_metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
        || final_metadata.len() > MAX_PROVIDER_STATE_BYTES
    {
        return Err(format!(
            "provider state is not a bounded regular file: {}",
            path.display()
        ));
    }
    if final_metadata.len() != initial_length || content.len() as u64 != initial_length {
        return Err(format!(
            "provider state changed while being read: {}",
            path.display()
        ));
    }
    Ok(Some(content))
}

fn validate_provider_state(value: &Value) -> Result<(), String> {
    let object = value
        .as_object()
        .ok_or_else(|| "expected a JSON object".to_owned())?;
    let status = object
        .get("status")
        .and_then(Value::as_str)
        .ok_or_else(|| "status is invalid".to_owned())?;
    let expected: &[&str] = match status {
        "unavailable" | "ready" => &["schema", "status", "inputRevision", "token"],
        _ => return Err("status is invalid".to_owned()),
    };
    if object.len() != expected.len()
        || expected
            .iter()
            .any(|name| !object.get(*name).is_some_and(Value::is_string))
    {
        return Err("shape is invalid".to_owned());
    }
    if object["schema"] != PROVIDER_STATE_SCHEMA {
        return Err("schema is invalid".to_owned());
    }
    if !valid_revision(object["inputRevision"].as_str().unwrap_or_default()) {
        return Err("input revision is invalid".to_owned());
    }
    if !is_lower_hex(object["token"].as_str().unwrap_or_default(), 32) {
        return Err("publication token is invalid".to_owned());
    }
    Ok(())
}

fn valid_revision(value: &str) -> bool {
    value.len() == REVISION_PREFIX.len() + 64
        && value.starts_with(REVISION_PREFIX)
        && is_lower_hex(&value[REVISION_PREFIX.len()..], 64)
}

fn is_lower_hex(value: &str, length: usize) -> bool {
    value.len() == length
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn validate_provider_directory_chain(data_root: &Path, module_root: &Path) -> Result<(), String> {
    let relative = module_root.strip_prefix(data_root).map_err(|_| {
        format!(
            "provider directory '{}' is outside Entry DataRoot '{}'",
            module_root.display(),
            data_root.display()
        )
    })?;
    let mut current = data_root.to_path_buf();
    if !validate_existing_directory(&current)? {
        return Ok(());
    }
    for component in relative.components() {
        let Component::Normal(name) = component else {
            return Err(format!(
                "provider directory '{}' is not a canonical DataRoot descendant",
                module_root.display()
            ));
        };
        current.push(name);
        if !validate_existing_directory(&current)? {
            return Ok(());
        }
    }
    Ok(())
}

fn validate_existing_directory(path: &Path) -> Result<bool, String> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => {
            return Err(format!(
                "cannot inspect provider directory '{}': {error}",
                path.display()
            ));
        }
    };
    if !metadata.is_dir() || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(format!(
            "provider directory is not a regular directory: {}",
            path.display()
        ));
    }
    Ok(true)
}

fn inspect_export_root(root: &Path) -> Result<bool, String> {
    if !regular_directory(root) {
        return Ok(false);
    }
    fs::read_dir(root)
        .map_err(|error| format!("cannot inspect export '{}': {error}", root.display()))?;
    Ok(true)
}

fn regular_directory(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|metadata| {
        metadata.is_dir() && metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT == 0
    })
}

#[cfg(test)]
mod tests {
    use std::io::Write;
    use std::sync::atomic::{AtomicU64, Ordering};

    use serde_json::json;

    use super::{MAX_PROVIDER_STATE_BYTES, read_provider_state_bytes, validate_provider_state};

    static NEXT: AtomicU64 = AtomicU64::new(0);

    fn revision() -> String {
        format!("sha256-{}", "a".repeat(64))
    }

    #[test]
    fn accepts_exact_unavailable_and_ready_states() {
        let unavailable = json!({
            "schema": "swawkit.command-provider-state/v3",
            "status": "unavailable",
            "inputRevision": revision(),
            "token": "1".repeat(32),
        });
        let ready = json!({
            "schema": "swawkit.command-provider-state/v3",
            "status": "ready",
            "inputRevision": revision(),
            "token": "2".repeat(32),
        });

        assert_eq!(validate_provider_state(&unavailable), Ok(()));
        assert_eq!(validate_provider_state(&ready), Ok(()));
    }

    #[test]
    fn rejects_incomplete_or_extended_provider_states() {
        let missing_token = json!({
            "schema": "swawkit.command-provider-state/v3",
            "status": "ready",
            "inputRevision": revision(),
        });
        let extended = json!({
            "schema": "swawkit.command-provider-state/v3",
            "status": "unavailable",
            "inputRevision": revision(),
            "token": "3".repeat(32),
            "reason": "stale",
        });

        assert_eq!(
            validate_provider_state(&missing_token),
            Err("shape is invalid".to_owned())
        );
        assert_eq!(
            validate_provider_state(&extended),
            Err("shape is invalid".to_owned())
        );
    }

    #[test]
    fn rejects_invalid_revision_token_status_and_retired_exports() {
        let invalid = [
            json!({
                "schema": "swawkit.command-provider-state/v3",
                "status": "ready",
                "inputRevision": format!("sha256-{}", "A".repeat(64)),
                "token": "4".repeat(32),
            }),
            json!({
                "schema": "swawkit.command-provider-state/v3",
                "status": "ready",
                "inputRevision": revision(),
                "token": "g".repeat(32),
            }),
            json!({
                "schema": "swawkit.command-provider-state/v3",
                "status": "stale",
                "inputRevision": revision(),
                "token": "5".repeat(32),
            }),
            json!({
                "schema": "swawkit.command-provider-state/v2",
                "status": "ready",
                "inputRevision": revision(),
                "token": "6".repeat(32),
            }),
            json!({
                "schema": "swawkit.command-provider-state/v3",
                "status": "ready",
                "inputRevision": revision(),
                "token": "7".repeat(32),
                "exports": [],
            }),
        ];

        for value in invalid {
            assert!(validate_provider_state(&value).is_err());
        }
    }

    #[test]
    fn bounded_reader_rejects_growth_after_opening_the_same_handle() {
        let fixture = StateFixture::new();
        std::fs::write(&fixture.path, b"{}").unwrap();

        let error = read_provider_state_bytes(&fixture.path, |path| {
            let mut file = std::fs::OpenOptions::new().append(true).open(path)?;
            file.write_all(b" ")
        })
        .unwrap_err();

        assert!(error.contains("changed while being read"), "{error}");
    }

    #[test]
    fn bounded_reader_rejects_oversized_and_reparse_states() {
        let fixture = StateFixture::new();
        std::fs::write(
            &fixture.path,
            vec![b' '; MAX_PROVIDER_STATE_BYTES as usize + 1],
        )
        .unwrap();
        assert!(
            read_provider_state_bytes(&fixture.path, |_| Ok(()))
                .unwrap_err()
                .contains("bounded regular file")
        );

        let target = fixture.root.join("target.json");
        let link = fixture.root.join("link.json");
        std::fs::write(&target, b"{}").unwrap();
        if let Err(error) = std::os::windows::fs::symlink_file(&target, &link) {
            eprintln!("skipping provider state reparse test: {error}");
            return;
        }
        assert!(
            read_provider_state_bytes(&link, |_| Ok(()))
                .unwrap_err()
                .contains("bounded regular file")
        );
    }

    struct StateFixture {
        root: std::path::PathBuf,
        path: std::path::PathBuf,
    }

    impl StateFixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "swawkit-provider-state-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir_all(&root).unwrap();
            let path = root.join("_state.json");
            Self { root, path }
        }
    }

    impl Drop for StateFixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }
}
