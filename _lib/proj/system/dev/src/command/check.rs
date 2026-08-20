use std::ffi::OsString;

use serde::Serialize;

use super::context::CommandContext;
use swawkit_proj_dev::development::setup::{
    PRODUCER_CONTRACT, PRODUCER_EXPORT, environment::verify_ready_export,
};

const CHECK_PROTOCOL: &str = "swawkit.proj.dev-setup-check/v1";
const PROVIDER_ADDRESS: &str = ".dev/setup";

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct CheckDocument {
    protocol: &'static str,
    provider: &'static str,
    export: &'static str,
    contract: &'static str,
    ready: bool,
    status: &'static str,
    message: Option<String>,
}

#[derive(Debug)]
struct CheckOutcome {
    exit_code: u8,
    output: String,
}

pub(super) fn run(context: &CommandContext, arguments: &[OsString]) -> Result<u8, String> {
    let outcome = execute(context, arguments)?;
    println!("{}", outcome.output);
    Ok(outcome.exit_code)
}

fn execute(context: &CommandContext, arguments: &[OsString]) -> Result<CheckOutcome, String> {
    let (export, json) = match arguments {
        [export] => (unicode(export, "Export ID")?, false),
        [export, format] if format == "--json" => (unicode(export, "Export ID")?, true),
        _ => return Err(usage()),
    };
    if export != PRODUCER_EXPORT {
        return Err(format!(
            "unsupported {PROVIDER_ADDRESS} Export ID '{export}'; expected '{PRODUCER_EXPORT}'"
        ));
    }

    let result = verify_ready_export(&context.data_root, context.input_revision());
    let document = document(result, context);
    let output = if json {
        serde_json::to_string_pretty(&document)
            .map_err(|error| format!("cannot serialize Dev setup check: {error}"))?
    } else {
        render_text(&document)
    };
    Ok(CheckOutcome {
        exit_code: if document.ready { 0 } else { 1 },
        output,
    })
}

fn document(result: Result<(), String>, context: &CommandContext) -> CheckDocument {
    match result {
        Ok(()) => CheckDocument {
            protocol: CHECK_PROTOCOL,
            provider: PROVIDER_ADDRESS,
            export: PRODUCER_EXPORT,
            contract: PRODUCER_CONTRACT,
            ready: true,
            status: "ready",
            message: None,
        },
        Err(message) => CheckDocument {
            protocol: CHECK_PROTOCOL,
            provider: PROVIDER_ADDRESS,
            export: PRODUCER_EXPORT,
            contract: PRODUCER_CONTRACT,
            ready: false,
            status: "not-ready",
            message: Some(format!("{message} Run '{}'.", context.repair_invocation())),
        },
    }
}

fn render_text(document: &CheckDocument) -> String {
    let mut lines = vec![
        format!("Provider: {}", document.provider),
        format!("Export: {}", document.export),
        format!("Contract: {}", document.contract),
        format!("Ready: {}", if document.ready { "yes" } else { "no" }),
        format!("Status: {}", document.status),
    ];
    if let Some(message) = &document.message {
        lines.push(format!("Message: {message}"));
    }
    lines.join("\n")
}

fn unicode<'a>(value: &'a OsString, label: &str) -> Result<&'a str, String> {
    value
        .to_str()
        .ok_or_else(|| format!("{label} is not valid Unicode"))
}

fn usage() -> String {
    ".dev/setup/check requires <export-id> followed by optional --json".to_owned()
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    use super::*;
    use serde_json::Value;
    use swawkit_proj_dev::development::setup::PUBLICATION_TOKEN_VARIABLE;
    use swawkit_proj_dev::development::setup::environment::EnvironmentPlan;
    use swawkit_proj_dev::development::setup::provider::SetupProvider;

    static NEXT: AtomicU64 = AtomicU64::new(0);

    #[test]
    fn json_protocol_and_exit_one_are_stable_for_a_missing_publication() {
        let fixture = Fixture::new();
        let outcome = execute(
            &fixture.context,
            &[OsString::from("environment"), OsString::from("--json")],
        )
        .unwrap();

        assert_eq!(outcome.exit_code, 1);
        let document: Value = serde_json::from_str(&outcome.output).unwrap();
        let mut fields = document
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>();
        fields.sort_unstable();
        assert_eq!(
            fields,
            [
                "contract", "export", "message", "protocol", "provider", "ready", "status"
            ]
        );
        assert_eq!(document["protocol"], CHECK_PROTOCOL);
        assert_eq!(document["provider"], PROVIDER_ADDRESS);
        assert_eq!(document["export"], PRODUCER_EXPORT);
        assert_eq!(document["contract"], PRODUCER_CONTRACT);
        assert_eq!(document["ready"], false);
        assert_eq!(document["status"], "not-ready");
        assert!(
            document["message"]
                .as_str()
                .unwrap()
                .contains("fixture .dev/setup")
        );
    }

    #[test]
    fn ready_document_has_no_diagnostic() {
        let fixture = Fixture::new();
        let document = document(Ok(()), &fixture.context);

        assert!(document.ready);
        assert_eq!(document.status, "ready");
        assert_eq!(document.message, None);
    }

    #[test]
    fn ready_publication_returns_the_frozen_success_document() {
        let fixture = Fixture::new();
        fixture.publish_ready();

        let outcome = execute(
            &fixture.context,
            &[OsString::from("environment"), OsString::from("--json")],
        )
        .unwrap();
        assert_eq!(outcome.exit_code, 0);
        let document: Value = serde_json::from_str(&outcome.output).unwrap();
        assert_eq!(document["protocol"], CHECK_PROTOCOL);
        assert_eq!(document["provider"], PROVIDER_ADDRESS);
        assert_eq!(document["export"], PRODUCER_EXPORT);
        assert_eq!(document["contract"], PRODUCER_CONTRACT);
        assert_eq!(document["ready"], true);
        assert_eq!(document["status"], "ready");
        assert_eq!(document["message"], Value::Null);
    }

    #[test]
    fn rejects_unknown_exports_and_ambiguous_arguments() {
        let fixture = Fixture::new();
        let unknown = execute(&fixture.context, &[OsString::from("tools")]).unwrap_err();
        assert!(unknown.contains("expected 'environment'"));
        assert_eq!(execute(&fixture.context, &[]).unwrap_err(), usage());
        assert_eq!(
            execute(
                &fixture.context,
                &[OsString::from("environment"), OsString::from("--text")]
            )
            .unwrap_err(),
            usage()
        );
    }

    struct Fixture {
        root: PathBuf,
        context: CommandContext,
    }

    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "swawkit-dev-check-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir_all(&root).unwrap();
            let settings =
                swawkit_proj_dev::development::setup::settings::DevSettingsStore::new(&root)
                    .snapshot()
                    .unwrap();
            let context = CommandContext {
                data_root: root.clone(),
                export_root: root.join("modules/system/dev/setup/export"),
                entry_command: "fixture".to_owned(),
                cache_data_root: root.join("cache"),
                settings,
            };
            Self { root, context }
        }

        fn publish_ready(&self) {
            let provider = SetupProvider::new(&self.root, self.context.input_revision()).unwrap();
            let publication = provider.start().unwrap();
            let mut plan = EnvironmentPlan::default();
            plan.set(
                PUBLICATION_TOKEN_VARIABLE,
                Some(publication.token().to_owned()),
            )
            .unwrap();
            plan.render().publish(&self.root).unwrap();
            plan.publish_export(
                &self.root,
                publication.input_revision(),
                publication.token(),
                None,
                None,
            )
            .unwrap();
            provider.complete(&publication).unwrap();
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }
}
