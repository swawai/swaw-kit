use serde::Serialize;
use swawkit_proj_protocol::FacetRoute;

use crate::run_journal::{RunJournalEvent, RunJournalSource};

pub(crate) const COMMAND_RUN_PROTOCOL: &str = "swawkit.command-run/v2";
const MAX_ARGUMENT_COUNT: usize = 128;
const MAX_ARGUMENT_UTF16: usize = 4096;
const MAX_COMMAND_UTF16: usize = 8192;

#[derive(Debug)]
pub(crate) struct StartFacetRunRequest {
    pub route: FacetRoute,
    pub tail: Vec<String>,
    pub source: RunJournalSource,
}

impl StartFacetRunRequest {
    pub(crate) fn validate(&self) -> Result<(), &'static str> {
        validate_invocation(&self.route.canonical_route(), &self.tail)
    }
}

pub(super) fn validate_invocation(address: &str, arguments: &[String]) -> Result<(), &'static str> {
    if address.is_empty() {
        return Err("command address cannot be empty");
    }
    if arguments.len() > MAX_ARGUMENT_COUNT {
        return Err("a command run accepts at most 128 arguments");
    }
    if address.contains('\0') || arguments.iter().any(|value| value.contains('\0')) {
        return Err("command addresses and arguments cannot contain NUL characters");
    }

    let address_units = address.encode_utf16().count();
    if address_units > MAX_ARGUMENT_UTF16
        || arguments
            .iter()
            .any(|value| value.encode_utf16().count() > MAX_ARGUMENT_UTF16)
    {
        return Err("each command address or argument accepts at most 4096 UTF-16 code units");
    }
    let total_units = address_units
        + arguments
            .iter()
            .map(|value| value.encode_utf16().count())
            .sum::<usize>();
    if total_units > MAX_COMMAND_UTF16 {
        return Err("a command run accepts at most 8192 UTF-16 code units in total");
    }
    Ok(())
}

pub(crate) struct RuntimeQueryOutput {
    pub stdout: String,
    pub exit_code: i32,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CommandRunDocument {
    pub protocol: &'static str,
    pub id: String,
    pub address: String,
    pub state: CommandRunState,
    pub exit_code: Option<i32>,
    pub error: Option<String>,
    pub next_cursor: u64,
    pub events: Vec<RunJournalEvent>,
    pub truncated: bool,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum CommandRunState {
    #[default]
    Running,
    Canceling,
    Exited,
    Canceled,
    Failed,
}

impl CommandRunState {
    pub(super) fn is_terminal(self) -> bool {
        matches!(self, Self::Exited | Self::Canceled | Self::Failed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(tail: Vec<String>) -> StartFacetRunRequest {
        StartFacetRunRequest {
            route: FacetRoute::parse("$/system::demo/execute").expect("test Facet Route"),
            tail,
            source: RunJournalSource::Web,
        }
    }

    #[test]
    fn validates_argument_limits_without_a_transport() {
        assert!(request(vec![]).validate().is_ok());
        assert!(request(vec!["x".to_owned(); 129]).validate().is_err());
        assert!(request(vec!["x".repeat(4097)]).validate().is_err());
        assert!(
            request(vec!["contains\0nul".to_owned()])
                .validate()
                .is_err()
        );
    }

    #[test]
    fn validates_the_address_utf16_limit() {
        let exact = "😀".repeat(MAX_ARGUMENT_UTF16 / 2);
        assert_eq!(exact.encode_utf16().count(), MAX_ARGUMENT_UTF16);
        assert!(validate_invocation(&exact, &[]).is_ok());

        let oversized = format!("{exact}x");
        assert_eq!(oversized.encode_utf16().count(), MAX_ARGUMENT_UTF16 + 1);
        assert!(validate_invocation(&oversized, &[]).is_err());
    }

    #[test]
    fn validates_the_total_arguments_utf16_limit() {
        let exact = vec![
            "x".repeat(MAX_ARGUMENT_UTF16),
            "y".repeat(MAX_ARGUMENT_UTF16 - 1),
        ];
        assert!(validate_invocation("a", &exact).is_ok());

        let oversized = vec![
            "x".repeat(MAX_ARGUMENT_UTF16),
            "y".repeat(MAX_ARGUMENT_UTF16),
        ];
        assert!(validate_invocation("a", &oversized).is_err());
    }
}
