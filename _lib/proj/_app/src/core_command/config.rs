use std::ffi::OsString;

use crate::entry_config::{EntryConfigRecord, EntryConfigStore, PROJECT_ROOT_ADDRESS};

use super::{CoreCommandError, CoreCommandOutcome};

/// Applies one typed Entry Config setting through the same atomic store used
/// by the Web API. The returned stdout is complete and transport-neutral.
pub fn set(
    address: &str,
    arguments: &[OsString],
    store: &EntryConfigStore,
) -> Result<CoreCommandOutcome, CoreCommandError> {
    let value = match arguments {
        [option] if address == PROJECT_ROOT_ADDRESS && option == "--clear" => None,
        [value] => Some(
            value
                .to_str()
                .ok_or_else(|| {
                    CoreCommandError::arguments("Entry Config value is not valid Unicode")
                })?
                .to_owned(),
        ),
        _ => {
            let suffix = if address == PROJECT_ROOT_ADDRESS {
                "<value> | --clear"
            } else {
                "<value>"
            };
            return Err(CoreCommandError::arguments(format!(
                "usage: {address} {suffix}"
            )));
        }
    };
    if !EntryConfigRecord::is_setting_address(address) {
        return Err(CoreCommandError::domain(format!(
            "Catalog invariant failed for '{address}': Entry Config setting address is invalid"
        )));
    }

    let document = store
        .update_setting(address, value)
        .map_err(|error| CoreCommandError::domain(error.to_string()))?;
    let output = serde_json::to_string_pretty(&document)
        .map_err(|error| CoreCommandError::serialization("cannot serialize entry config", error))?;
    Ok(CoreCommandOutcome::success(format!("{output}\n")))
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    use serde_json::Value;

    use super::*;
    use crate::entry_config::EntryConfigState;

    static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

    struct Fixture {
        root: PathBuf,
        store: EntryConfigStore,
    }

    impl Fixture {
        fn new() -> Self {
            let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
            let root = std::env::temp_dir().join(format!(
                "swawkit-core-entry-config-{}-{sequence}",
                std::process::id()
            ));
            let home = root.join("home");
            let data_root = home.join("data/proj.fixture");
            fs::create_dir_all(&data_root).expect("create fixture directories");
            let store = EntryConfigStore::new(&home, &data_root);
            Self { root, store }
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    #[test]
    fn setting_returns_the_complete_json_stdout_and_updates_the_store() {
        let fixture = Fixture::new();
        let outcome = set(".entry/language", &[OsString::from("en")], &fixture.store)
            .expect("set Entry Config field");

        let output: Value = serde_json::from_str(&outcome.stdout).unwrap();
        assert_eq!(output["config"]["language"], "en");
        let EntryConfigState::Ready(config) = fixture.store.read() else {
            panic!("expected ready Entry Config");
        };
        assert_eq!(config.record().language, "en");
    }

    #[test]
    fn project_binding_can_be_cleared() {
        let fixture = Fixture::new();
        set(
            PROJECT_ROOT_ADDRESS,
            &[OsString::from("${SWAWKIT_HOME}")],
            &fixture.store,
        )
        .unwrap();
        let outcome = set(
            PROJECT_ROOT_ADDRESS,
            &[OsString::from("--clear")],
            &fixture.store,
        )
        .unwrap();
        let output: Value = serde_json::from_str(&outcome.stdout).unwrap();
        assert_eq!(output["config"]["projectRoot"], Value::Null);
    }
}
