use std::ffi::OsString;

use swawkit_proj_dev::development::setup::settings::{DevSettingsDocument, DevSettingsStore};

use super::context::CommandContext;

pub(super) fn show(context: &CommandContext, arguments: &[OsString]) -> Result<u8, String> {
    if !arguments.is_empty() {
        return Err(".dev/settings does not accept dynamic arguments".to_owned());
    }
    print_document(&context.settings.document())?;
    Ok(0)
}

pub(super) fn set(
    context: &CommandContext,
    address: &str,
    arguments: &[OsString],
) -> Result<u8, String> {
    let document = update(context, address, arguments)?;
    print_document(&document)?;
    Ok(0)
}

fn update(
    context: &CommandContext,
    address: &str,
    arguments: &[OsString],
) -> Result<DevSettingsDocument, String> {
    let (value, expected_revision) = match arguments {
        [value] => (unicode(value, "setting value")?, None),
        [value, option, revision] if option == "--if-revision" => (
            unicode(value, "setting value")?,
            Some(unicode(revision, "Dev Settings revision")?),
        ),
        _ => {
            return Err(format!(
                "usage: {address} <value> [--if-revision <revision>]"
            ));
        }
    };
    DevSettingsStore::new(&context.data_root)
        .update_setting(address, value.to_owned(), expected_revision)
        .map(|snapshot| snapshot.document())
}

fn print_document(document: &impl serde::Serialize) -> Result<(), String> {
    let output = serde_json::to_string_pretty(document)
        .map_err(|error| format!("cannot serialize Dev Settings document: {error}"))?;
    println!("{output}");
    Ok(())
}

fn unicode<'a>(value: &'a OsString, subject: &str) -> Result<&'a str, String> {
    value
        .to_str()
        .ok_or_else(|| format!("{subject} is not valid Unicode"))
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    use swawkit_proj_dev::development::setup::settings::{
        SETTINGS_DOCUMENT_PROTOCOL, setting_addresses,
    };

    use super::*;

    static NEXT: AtomicU64 = AtomicU64::new(0);

    #[test]
    fn ten_runtime_setters_return_the_frozen_document_protocol() {
        let fixture = Fixture::new();
        let initial = fixture.context.settings.document();
        for address in setting_addresses() {
            let value = initial.values[*address].clone();
            let document = update(&fixture.context, address, &[OsString::from(value)]).unwrap();
            assert_eq!(document.protocol, SETTINGS_DOCUMENT_PROTOCOL);
            assert_eq!(document.values.len(), 10);
            let value = serde_json::to_value(document).unwrap();
            assert_eq!(value["protocol"], SETTINGS_DOCUMENT_PROTOCOL);
            assert_eq!(value["settings"]["schema"], "swawkit.proj-dev-settings/v1");
        }
    }

    #[test]
    fn optional_revision_is_a_real_compare_and_swap() {
        let fixture = Fixture::new();
        let saved = update(
            &fixture.context,
            ".dev/bun/version",
            &[
                OsString::from("1.2.16"),
                OsString::from("--if-revision"),
                OsString::from("missing"),
            ],
        )
        .unwrap();
        assert_ne!(saved.revision, "missing");
        let error = update(
            &fixture.context,
            ".dev/bun/version",
            &[
                OsString::from("1.2.17"),
                OsString::from("--if-revision"),
                OsString::from("missing"),
            ],
        )
        .unwrap_err();
        assert!(error.contains("changed since revision"));
    }

    struct Fixture {
        root: PathBuf,
        context: CommandContext,
    }

    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "swawkit-dev-settings-command-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(&root).unwrap();
            let settings = DevSettingsStore::new(&root).snapshot().unwrap();
            Self {
                context: CommandContext {
                    data_root: root.clone(),
                    export_root: root.join("modules/system/dev/setup/export"),
                    entry_command: "fixture".to_owned(),
                    cache_data_root: root.join("cache"),
                    settings,
                },
                root,
            }
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }
}
