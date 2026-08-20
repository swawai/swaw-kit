use std::ffi::OsString;

use crate::profile::{EntryProfileRecord, EntryProfileStore};

use super::{CoreCommandError, CoreCommandOutcome};

/// Applies one typed Entry Profile setting through the same atomic store used
/// by the Web API. The returned stdout is complete and transport-neutral.
pub fn set(
    address: &str,
    arguments: &[OsString],
    store: &EntryProfileStore,
) -> Result<CoreCommandOutcome, CoreCommandError> {
    let [value] = arguments else {
        return Err(CoreCommandError::arguments(format!(
            "usage: {address} <value>"
        )));
    };
    let value = value
        .to_str()
        .ok_or_else(|| CoreCommandError::arguments("profile value is not valid Unicode"))?;
    if !EntryProfileRecord::is_profile_setting_address(address) {
        return Err(CoreCommandError::domain(format!(
            "Catalog invariant failed for '{address}': Entry Profile setting address is invalid"
        )));
    }

    let document = store
        .update_setting(address, value.to_owned())
        .map_err(|error| CoreCommandError::domain(error.to_string()))?;
    let output = serde_json::to_string_pretty(&document).map_err(|error| {
        CoreCommandError::serialization("cannot serialize entry profile", error)
    })?;
    Ok(CoreCommandOutcome::success(format!("{output}\n")))
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    use serde_json::Value;

    use super::*;
    use crate::profile::EntryProfileState;

    static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

    struct Fixture {
        root: PathBuf,
        data_root: PathBuf,
        store: EntryProfileStore,
    }

    impl Fixture {
        fn new() -> Self {
            let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
            let root = std::env::temp_dir().join(format!(
                "swawkit-core-profile-{}-{sequence}",
                std::process::id()
            ));
            let home = root.join("home");
            let data_root = home.join("data/proj.fixture");
            fs::create_dir_all(&data_root).expect("create fixture directories");
            let store = EntryProfileStore::new(&home, &data_root);
            Self {
                root,
                data_root,
                store,
            }
        }

        fn provider_state_path(&self) -> PathBuf {
            self.data_root.join("modules/system/dev/setup/_state.json")
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
            .expect("set profile field");

        assert_eq!(outcome.exit_code, 0);
        assert!(outcome.stdout.ends_with('\n'));
        let output: Value = serde_json::from_str(&outcome.stdout).expect("profile JSON stdout");
        assert_eq!(output["profile"]["language"], "en");
        let EntryProfileState::Ready(profile) = fixture.store.read() else {
            panic!("expected ready profile");
        };
        assert_eq!(profile.record().language, "en");
    }

    #[test]
    fn malformed_invocations_are_typed_and_do_not_write_the_profile() {
        let fixture = Fixture::new();

        let error = set(".entry/language", &[], &fixture.store).unwrap_err();
        assert!(matches!(error, CoreCommandError::Arguments { .. }));
        assert_eq!(error.to_string(), "usage: .entry/language <value>");

        let error = set(".entry/unknown", &[OsString::from("value")], &fixture.store).unwrap_err();
        assert!(matches!(error, CoreCommandError::Domain { .. }));
        assert!(error.to_string().contains("Catalog invariant failed"));
        assert!(!fixture.store.path().exists());
    }

    #[test]
    fn provider_inputs_keep_the_store_provider_state_transaction() {
        let fixture = Fixture::new();
        set(".entry/language", &[OsString::from("en")], &fixture.store)
            .expect("create profile through a non-provider setting");
        let initial = fs::read(fixture.provider_state_path()).expect("initial provider state");

        set(
            ".entry/language",
            &[OsString::from("zh-CN")],
            &fixture.store,
        )
        .expect("update non-provider setting");
        assert_eq!(fs::read(fixture.provider_state_path()).unwrap(), initial);

        set(
            ".dev/bun/version",
            &[OsString::from("1.2.16")],
            &fixture.store,
        )
        .expect("update provider setting");
        assert_ne!(fs::read(fixture.provider_state_path()).unwrap(), initial);
    }
}
