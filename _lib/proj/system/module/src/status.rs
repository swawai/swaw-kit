use std::ffi::OsString;

use swawkit_proj_protocol::serde::{self, Serialize};
use swawkit_proj_protocol::serde_json;

use crate::manifest::discover_native_domain;
use crate::release_store::read_selected_from_data_root;
use crate::snapshot::build_input_snapshot;
use crate::transport::CommandContext;

const STATUS_SCHEMA: &str = "swawkit.module-status/v1";

pub(crate) fn run(context: &CommandContext, arguments: &[OsString]) -> Result<(), String> {
    let (address, json) = match arguments {
        [address] => (unicode(address)?, false),
        [address, format] if format == "--json" => (unicode(address)?, true),
        _ => {
            return Err(
                ".module/status requires <native command address> followed by optional --json"
                    .to_owned(),
            );
        }
    };
    let document = inspect(context, address)?;
    if json {
        let output = serde_json::to_string(&document)
            .map_err(|error| format!("cannot serialize Module status: {error}"))?;
        println!("{output}");
    } else {
        println!(
            "[{}] {} -> {}{}",
            document.state.label(),
            document.address,
            document.owner,
            document
                .release_id
                .as_deref()
                .map(|id| format!("  {id}"))
                .unwrap_or_default()
        );
    }
    Ok(())
}

fn inspect(context: &CommandContext, address: &str) -> Result<StatusDocument, String> {
    let domain = discover_native_domain(&context.system_root, &context.module_roots, address)?;
    let execution_contract_revision = domain.execution_contract_revision()?;
    let snapshot = build_input_snapshot(
        &domain.owner_directory,
        &execution_contract_revision,
        &domain.nested_owner_directories,
    )?;
    let selected = read_selected_from_data_root(&context.data_root, &domain.owner_identity)?;
    let (state, selected_build_input_revision, release_id) = match selected {
        None => (StatusState::Unpublished, None, None),
        Some(selected) => {
            let current = selected.manifest.build_input_revision == snapshot.revision
                && selected.manifest.execution_contract_revision == execution_contract_revision;
            (
                if current {
                    StatusState::Current
                } else {
                    StatusState::Outdated
                },
                Some(selected.manifest.build_input_revision),
                Some(selected.release_id),
            )
        }
    };
    Ok(StatusDocument {
        protocol: STATUS_SCHEMA,
        address: domain.requested_address,
        owner: domain.owner_address,
        state,
        build_input_revision: snapshot.revision,
        selected_build_input_revision,
        release_id,
    })
}

fn unicode(value: &OsString) -> Result<&str, String> {
    value
        .to_str()
        .ok_or_else(|| "native command address must be valid Unicode".to_owned())
}

#[derive(Debug, PartialEq, Eq, Serialize)]
#[serde(crate = "serde", rename_all = "camelCase")]
struct StatusDocument {
    protocol: &'static str,
    address: String,
    owner: String,
    state: StatusState,
    build_input_revision: String,
    selected_build_input_revision: Option<String>,
    release_id: Option<String>,
}

#[derive(Debug, PartialEq, Eq, Serialize)]
#[serde(crate = "serde", rename_all = "lowercase")]
enum StatusState {
    Unpublished,
    Current,
    Outdated,
}

impl StatusState {
    fn label(&self) -> &'static str {
        match self {
            Self::Unpublished => "UNPUBLISHED",
            Self::Current => "CURRENT",
            Self::Outdated => "OUTDATED",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::filesystem::unique_token;
    use crate::manifest::discover_native_domain;
    use crate::release_store::{prepare_native_root, publish};
    use crate::snapshot::build_input_snapshot;
    use std::collections::BTreeMap;
    use std::fs;
    use std::path::PathBuf;
    use swawkit_proj_protocol::CommandRelease;

    struct Fixture {
        root: PathBuf,
        system: PathBuf,
        modules: PathBuf,
        data: PathBuf,
    }

    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!("swawkit-status-{}", unique_token()));
            let system = root.join("system");
            let modules = root.join("modules");
            let owner = modules.join("context");
            let data = root.join("data");
            fs::create_dir_all(&system).unwrap();
            fs::create_dir_all(owner.join("_src")).unwrap();
            fs::create_dir(&data).unwrap();
            fs::write(
                owner.join("swawkit.module.json"),
                r#"{"schema":"swawkit.command-module/v10","execution":{"type":"native"}}"#,
            )
            .unwrap();
            fs::write(owner.join("_src/main.rs"), "fn main() {}\n").unwrap();
            Self {
                root,
                system,
                modules,
                data,
            }
        }

        fn context(&self) -> CommandContext {
            CommandContext {
                data_root: self.data.clone(),
                system_root: self.system.clone(),
                module_roots: BTreeMap::from([("swaw".to_owned(), self.modules.clone())]),
            }
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    #[test]
    fn unpublished_status_does_not_create_target_data_or_lock_files() {
        let fixture = Fixture::new();
        let document = inspect(&fixture.context(), "swaw/context").unwrap();
        assert_eq!(document.state, StatusState::Unpublished);
        assert!(document.selected_build_input_revision.is_none());
        assert!(document.release_id.is_none());
        assert!(!fixture.data.join("modules").exists());
    }

    #[test]
    fn system_native_command_status_uses_the_same_publication_flow() {
        let fixture = Fixture::new();
        let owner = fixture.system.join("context");
        fs::create_dir_all(owner.join("_src")).unwrap();
        fs::write(
            owner.join("swawkit.module.json"),
            r#"{"schema":"swawkit.command-module/v10","execution":{"type":"native"}}"#,
        )
        .unwrap();
        fs::write(owner.join("_src/main.rs"), "fn main() {}\n").unwrap();

        let document = inspect(&fixture.context(), ".context").unwrap();
        assert_eq!(document.address, ".context");
        assert_eq!(document.owner, ".context");
        assert_eq!(document.state, StatusState::Unpublished);
        assert!(!fixture.data.join("modules").exists());
    }

    #[test]
    fn status_rejects_an_unsafe_existing_data_root_ancestor() {
        let fixture = Fixture::new();
        fs::write(fixture.data.join("modules"), "not a directory").unwrap();
        let error = inspect(&fixture.context(), "swaw/context").unwrap_err();
        assert!(error.contains("must be a regular directory"), "{error}");
    }

    #[test]
    fn published_status_becomes_outdated_without_invalidating_the_release() {
        let fixture = Fixture::new();
        let context = fixture.context();
        let domain =
            discover_native_domain(&context.system_root, &context.module_roots, "swaw/context")
                .unwrap();
        let contract = domain.execution_contract_revision().unwrap();
        let snapshot = build_input_snapshot(
            &domain.owner_directory,
            &contract,
            &domain.nested_owner_directories,
        )
        .unwrap();
        let executable = b"fixture executable";
        let release = CommandRelease::new(
            domain.owner_address.clone(),
            snapshot.revision,
            contract,
            domain.commands(),
            executable,
        )
        .unwrap();
        let native_root = prepare_native_root(&context.data_root, &domain.owner_identity).unwrap();
        let publication = publish(&native_root, &release, executable).unwrap();

        let current = inspect(&context, "swaw/context").unwrap();
        assert_eq!(current.state, StatusState::Current);
        assert_eq!(
            current.release_id.as_deref(),
            Some(publication.release_id.as_str())
        );

        fs::write(
            fixture.modules.join("context/_src/main.rs"),
            "fn main() { println!(\"changed\"); }\n",
        )
        .unwrap();
        let outdated = inspect(&context, "swaw/context").unwrap();
        assert_eq!(outdated.state, StatusState::Outdated);
        assert_eq!(outdated.release_id, current.release_id);
        assert_eq!(
            outdated.selected_build_input_revision,
            current.selected_build_input_revision
        );
    }
}
