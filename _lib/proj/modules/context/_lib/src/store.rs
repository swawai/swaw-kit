use std::path::PathBuf;

use crate::error::{ContextError, ContextResult};
use crate::locking::ContextLock;
use crate::model::{
    ContextCommand, ContextRecord, MAX_NOTE_BYTES, MAX_PROMPT_BYTES, validate_command_address,
    validate_id, validate_text,
};
use crate::storage;

#[derive(Debug, Clone)]
pub(crate) struct ContextStore {
    data_root: PathBuf,
    module_data_root: PathBuf,
    records_root: PathBuf,
}

impl ContextStore {
    pub(crate) fn open(data_root: PathBuf, module_data_root: PathBuf) -> ContextResult<Self> {
        let directory = storage::ensure_context_directory(&data_root, &module_data_root)?;
        let legacy_root = storage::legacy_module_root(&data_root, &module_data_root)?;
        let _legacy_lock = legacy_root
            .as_deref()
            .map(ContextLock::acquire)
            .transpose()?;
        let _lock = ContextLock::acquire(&directory)?;
        storage::migrate_legacy_module_state(legacy_root.as_deref(), &module_data_root)?;
        let records_root = storage::prepare_context_state(&data_root, &module_data_root)?;
        Ok(Self {
            data_root,
            module_data_root,
            records_root,
        })
    }

    pub(crate) fn create(&self, id: &str) -> ContextResult<ContextRecord> {
        self.validate_resource_id(id)?;
        let directory = self.ensure_directory()?;
        let _lock = ContextLock::acquire(&self.module_data_root)?;
        let record = ContextRecord::empty(id);
        storage::publish_new_record(&directory, &record)?;
        Ok(record)
    }

    pub(crate) fn read(&self, id: &str) -> ContextResult<ContextRecord> {
        self.read_optional(id)?
            .ok_or_else(|| ContextError::new(format!("Context not found: {id}")))
    }

    pub(crate) fn read_optional(&self, id: &str) -> ContextResult<Option<ContextRecord>> {
        self.validate_resource_id(id)?;
        let Some(directory) =
            storage::existing_context_directory(&self.data_root, &self.records_root)?
        else {
            return Ok(None);
        };
        storage::read_optional_record(&directory, id)
    }

    pub(crate) fn list(&self) -> ContextResult<Vec<ContextRecord>> {
        let Some(directory) =
            storage::existing_context_directory(&self.data_root, &self.records_root)?
        else {
            return Ok(Vec::new());
        };
        storage::resource_directories(&directory)?
            .into_iter()
            .map(|(id, path)| storage::read_record(&path.join("_resource.json"), &id))
            .collect()
    }

    pub(crate) fn add_commands(
        &self,
        id: &str,
        commands: Vec<ContextCommand>,
    ) -> ContextResult<ContextRecord> {
        if commands.is_empty() {
            return Err(ContextError::new("at least one command must be added"));
        }
        for command in &commands {
            validate_command_address(&command.address)?;
        }
        self.update(id, move |record| {
            for command in commands {
                if !record.commands.contains(&command) {
                    record.commands.push(command);
                }
            }
            Ok(())
        })
    }

    pub(crate) fn remove_commands(
        &self,
        id: &str,
        addresses: &[String],
    ) -> ContextResult<ContextRecord> {
        if addresses.is_empty() {
            return Err(ContextError::new("at least one command must be removed"));
        }
        for address in addresses {
            validate_command_address(address)?;
        }
        self.update(id, |record| {
            let before = record.commands.len();
            record
                .commands
                .retain(|command| !addresses.contains(&command.address));
            if record.commands.len() == before {
                return Err(ContextError::new(format!(
                    "none of the requested commands belong to Context '{id}'"
                )));
            }
            Ok(())
        })
    }

    pub(crate) fn append_note(&self, id: &str, note: String) -> ContextResult<ContextRecord> {
        validate_text(&note, "Context note", MAX_NOTE_BYTES)?;
        self.update(id, move |record| {
            record.notes.push(note);
            Ok(())
        })
    }

    pub(crate) fn set_prompt(&self, id: &str, prompt: String) -> ContextResult<ContextRecord> {
        validate_text(&prompt, "Context prompt", MAX_PROMPT_BYTES)?;
        self.update(id, move |record| {
            record.prompt = prompt;
            Ok(())
        })
    }

    pub(crate) fn delete(&self, id: &str) -> ContextResult<()> {
        self.validate_resource_id(id)?;
        let directory = storage::existing_context_directory(&self.data_root, &self.records_root)?
            .ok_or_else(|| ContextError::new(format!("Context not found: {id}")))?;
        let _lock = ContextLock::acquire(&self.module_data_root)?;
        storage::delete_record(&directory, id)
    }

    fn update(
        &self,
        id: &str,
        change: impl FnOnce(&mut ContextRecord) -> ContextResult<()>,
    ) -> ContextResult<ContextRecord> {
        self.validate_resource_id(id)?;
        let directory = self.ensure_directory()?;
        let _lock = ContextLock::acquire(&self.module_data_root)?;
        let path = storage::context_path(&directory, id);
        let mut record = storage::read_record(&path, id)?;
        change(&mut record)?;
        storage::publish_record(&path, &record)?;
        Ok(record)
    }

    fn ensure_directory(&self) -> ContextResult<PathBuf> {
        storage::ensure_context_directory(&self.data_root, &self.records_root)
    }

    fn validate_resource_id(&self, id: &str) -> ContextResult<()> {
        validate_id(id)
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::{Arc, Barrier};

    use super::*;
    use crate::address::command_reference;

    static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

    struct Fixture {
        root: PathBuf,
        store: ContextStore,
    }

    impl Fixture {
        fn new() -> Self {
            let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
            let root = std::env::temp_dir().join(format!(
                "swawkit-context-domain-{}-{sequence}",
                std::process::id()
            ));
            let data_root = root.join("data/proj.fixture");
            fs::create_dir_all(&data_root).expect("create Context fixture DataRoot");
            let module_data_root = data_root.join("modules/swaw/context");
            Self {
                root,
                store: ContextStore::open(data_root, module_data_root).unwrap(),
            }
        }

        fn record_path(&self, id: &str) -> PathBuf {
            self.store.records_root.join(id).join("_resource.json")
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    fn command(address: &str) -> ContextCommand {
        command_reference(address).unwrap()
    }

    #[test]
    fn owns_the_complete_record_lifecycle() {
        let fixture = Fixture::new();
        fixture.store.create("build-app").unwrap();
        fixture
            .store
            .add_commands(
                "build-app",
                vec![command(".dev/status"), command("project/build/app")],
            )
            .unwrap();
        fixture
            .store
            .append_note("build-app", "Inspect first.".to_owned())
            .unwrap();
        let record = fixture
            .store
            .set_prompt("build-app", "Build the app.".to_owned())
            .unwrap();

        assert_eq!(fixture.store.read("build-app").unwrap(), record);
        assert_eq!(record.commands.len(), 2);
        assert_eq!(record.notes, ["Inspect first."]);
        fixture.store.delete("build-app").unwrap();
        assert!(!fixture.record_path("build-app").exists());
    }

    #[test]
    fn command_names_are_valid_context_ids_and_resources_are_sorted() {
        let fixture = Fixture::new();
        fixture.store.create("add").unwrap();
        fixture.store.create("zeta").unwrap();
        fixture.store.create("alpha").unwrap();
        assert_eq!(
            fixture
                .store
                .list()
                .unwrap()
                .into_iter()
                .map(|record| record.id)
                .collect::<Vec<_>>(),
            ["add", "alpha", "zeta"]
        );
    }

    #[test]
    fn migrates_legacy_root_records_once_before_opening_the_state_tree() {
        let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "swawkit-context-migration-{}-{sequence}",
            std::process::id()
        ));
        let data_root = root.join("data/proj.fixture");
        let module_data_root = data_root.join("modules/swaw/context");
        let legacy = module_data_root.join("legacy");
        fs::create_dir_all(&legacy).unwrap();
        storage::publish_record(
            &legacy.join("_resource.json"),
            &ContextRecord::empty("legacy"),
        )
        .unwrap();

        let store = ContextStore::open(data_root, module_data_root.clone()).unwrap();

        assert_eq!(store.read("legacy").unwrap().id, "legacy");
        assert!(!legacy.exists());
        assert_eq!(
            fs::read(module_data_root.join("state/version")).unwrap(),
            b"2\n"
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn moves_the_old_domain_state_and_upgrades_command_identities_once() {
        let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "swawkit-context-v2-migration-{}-{sequence}",
            std::process::id()
        ));
        let data_root = root.join("data/proj.fixture");
        let legacy_root = data_root.join("modules/kernel/.context");
        let legacy_record = legacy_root.join("state/contexts/release/_resource.json");
        fs::create_dir_all(legacy_record.parent().unwrap()).unwrap();
        fs::write(legacy_root.join("state/version"), b"1\n").unwrap();
        fs::write(
            &legacy_record,
            serde_json::to_vec_pretty(&serde_json::json!({
                "schema": "swawkit.context/v1",
                "id": "release",
                "commands": [
                    { "source": "control", "address": "..entry.language" },
                    { "source": "kernel", "address": ".dev.status" },
                    { "source": "action", "address": "build.app" }
                ],
                "notes": [],
                "prompt": ""
            }))
            .unwrap(),
        )
        .unwrap();
        let module_data_root = data_root.join("modules/swaw/context");
        fs::create_dir_all(module_data_root.join("_native/current")).unwrap();

        let store = ContextStore::open(data_root.clone(), module_data_root.clone()).unwrap();
        let record = store.read("release").unwrap();

        assert_eq!(record.schema, "swawkit.context/v2");
        assert_eq!(
            record
                .commands
                .iter()
                .map(|command| command.address.as_str())
                .collect::<Vec<_>>(),
            [".entry/language", ".dev/status", "project/build/app"]
        );
        assert_eq!(
            fs::read(module_data_root.join("state/version")).unwrap(),
            b"2\n"
        );
        assert!(!legacy_root.join("state").exists());
        assert!(module_data_root.join("_native/current").is_dir());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn serializes_concurrent_updates_with_a_domain_local_lock() {
        let fixture = Fixture::new();
        fixture.store.create("concurrent").unwrap();
        let store = Arc::new(fixture.store.clone());
        let barrier = Arc::new(Barrier::new(4));
        let threads = (0..4)
            .map(|index| {
                let store = Arc::clone(&store);
                let barrier = Arc::clone(&barrier);
                std::thread::spawn(move || {
                    barrier.wait();
                    store
                        .append_note("concurrent", format!("note-{index}"))
                        .unwrap();
                })
            })
            .collect::<Vec<_>>();
        for thread in threads {
            thread.join().unwrap();
        }
        let mut notes = store.read("concurrent").unwrap().notes;
        notes.sort();
        assert_eq!(notes, ["note-0", "note-1", "note-2", "note-3"]);
    }
}
