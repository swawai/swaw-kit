use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use crate::catalog::{CATALOG_PROTOCOL, CatalogSnapshot, CommandAdapter, CommandSpace};
use crate::command::ResolvedCommand;
use crate::context::EntryContext;
use crate::profile::{EntryProfileState, EntryProfileStore};

use super::*;

#[test]
fn runtime_preparation_rejects_lifecycle_and_unknown_core_handlers() {
    let fixture = Fixture::new();
    let lifecycle = fixture.command(".entry/git/name", "entry.profile.set");
    let error = match fixture.prepare(&lifecycle) {
        Ok(_) => panic!("lifecycle command unexpectedly prepared"),
        Err(error) => error,
    };
    assert!(error.to_string().contains("lifecycle command"));

    let unknown = fixture.command(".future", "future.handler");
    let error = match fixture.prepare(&unknown) {
        Ok(_) => panic!("unknown handler unexpectedly prepared"),
        Err(error) => error,
    };
    assert_eq!(
        error.to_string(),
        "unsupported Runtime Core command handler: future.handler"
    );

    let runtime_lifecycle = fixture.command(".runtime/cleanup", "runtime.cleanup");
    let error = match fixture.prepare(&runtime_lifecycle) {
        Ok(_) => panic!("Runtime lifecycle command unexpectedly prepared"),
        Err(error) => error,
    };
    assert!(error.to_string().contains("lifecycle command"));

    let mut non_core = fixture.command(".help", "meta.help");
    non_core.adapter = CommandAdapter::Exe;
    let error = match fixture.prepare(&non_core) {
        Ok(_) => panic!("non-Core command unexpectedly prepared"),
        Err(error) => error,
    };
    assert!(error.to_string().contains("not a System Core command"));

    let mut module_core = fixture.command(".help", "meta.help");
    module_core.space = CommandSpace::Module;
    module_core.namespace = Some("fixture".to_owned());
    let error = match fixture.prepare(&module_core) {
        Ok(_) => panic!("module-space Core command unexpectedly prepared"),
        Err(error) => error,
    };
    assert!(error.to_string().contains("not a System Core command"));

    let mut missing_handler = fixture.command(".help", "meta.help");
    missing_handler.handler = None;
    let error = match fixture.prepare(&missing_handler) {
        Ok(_) => panic!("handlerless Core command unexpectedly prepared"),
        Err(error) => error,
    };
    assert!(error.to_string().contains("Core command has no handler"));
}

#[test]
fn runtime_preparation_is_explicit_for_every_supported_handler() {
    let fixture = Fixture::new();
    for (address, handler) in [
        (".help", "meta.help"),
        (".check", "meta.check"),
        (".runs", "meta.runs"),
        (".dev/bun/mode", "entry.profile.set"),
    ] {
        let command = fixture.command(address, handler);
        fixture
            .prepare(&command)
            .unwrap_or_else(|error| panic!("{address}: {error}"));
    }
}

#[test]
fn runtime_preparation_defers_profile_arguments_and_mutation_until_execute() {
    let fixture = Fixture::new();
    let command = fixture.command(".dev/bun/mode", "entry.profile.set");
    let profile_path = fixture.data_root.join("_profile.json");

    let prepared = fixture
        .prepare_with_argv(&command, vec![command.address.clone().into()])
        .expect("prepare malformed profile invocation without parsing it");
    assert!(!profile_path.exists());

    let error = prepared.execute().unwrap_err();
    assert!(matches!(error, CoreCommandError::Arguments { .. }));
    assert_eq!(error.to_string(), "usage: .dev/bun/mode <value>");
    assert!(!profile_path.exists());
}

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    root: PathBuf,
    context: EntryContext,
    data_root: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "swawkit-prepared-core-{}-{sequence}",
            std::process::id()
        ));
        let swawkit_home = root.join("home");
        let data_root = swawkit_home.join("data/proj.fixture");
        Self {
            context: EntryContext {
                swawkit_home,
                data_root: data_root.clone(),
                runtime_root: root.join("runtime"),
                entry_file: root.join("fixture.exe"),
                entry_name: "fixture".to_owned(),
                entry_id: crate::entry::EntryId::parse(&"a".repeat(64)).unwrap(),
                invocation_directory: root.join("project"),
                product_executable: root.join("fixture-core.exe"),
                release_id: "fixture-release".to_owned(),
            },
            data_root,
            root,
        }
    }

    fn command(&self, address: &str, handler: &str) -> ResolvedCommand {
        let path = address
            .trim_start_matches('.')
            .split('/')
            .map(str::to_owned)
            .collect();
        ResolvedCommand {
            address: address.to_owned(),
            space: CommandSpace::System,
            namespace: None,
            path,
            directory: PathBuf::from("fixture-command"),
            entry_path: PathBuf::from("fixture-command/core"),
            adapter: CommandAdapter::Core,
            handler: Some(handler.to_owned()),
            product: None,
            native_owner: None,
        }
    }

    fn prepare(&self, command: &ResolvedCommand) -> Result<PreparedCoreCommand, CoreCommandError> {
        self.prepare_with_argv(command, vec![command.address.clone().into()])
    }

    fn prepare_with_argv(
        &self,
        command: &ResolvedCommand,
        argv: Vec<std::ffi::OsString>,
    ) -> Result<PreparedCoreCommand, CoreCommandError> {
        PreparedCoreCommand::for_runtime(
            command,
            argv,
            CatalogSnapshot {
                protocol: CATALOG_PROTOCOL,
                entry_name: "fixture".to_owned(),
                language: "en",
                commands: Vec::new(),
            },
            self.context.clone(),
            self.data_root.clone(),
            EntryProfileState::Missing {
                path: self.data_root.join("_profile.json"),
            },
            EntryProfileStore::new(&self.context.swawkit_home, &self.data_root),
        )
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}
