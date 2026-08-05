use serde::Serialize;

use super::{EntryProfileRecord, EntryProfileState};

/// Transport-neutral representation shared by the CLI and Web API.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EntryProfileDocument {
    pub protocol: &'static str,
    pub revision: String,
    pub status: &'static str,
    pub required_complete: bool,
    pub path: String,
    pub profile: EntryProfileRecord,
    pub resolved_target_project_root: Option<String>,
    pub error: Option<String>,
}

impl EntryProfileDocument {
    pub(super) fn from_state(state: EntryProfileState, path: String, revision: String) -> Self {
        match state {
            EntryProfileState::Missing { .. } => Self {
                protocol: "swawkit.entry-profile-state/v2",
                revision,
                status: "setupRequired",
                required_complete: false,
                path,
                profile: EntryProfileRecord::default(),
                resolved_target_project_root: None,
                error: None,
            },
            EntryProfileState::Invalid { record, error, .. } => Self {
                protocol: "swawkit.entry-profile-state/v2",
                revision,
                status: "invalid",
                required_complete: false,
                path,
                profile: record.unwrap_or_default(),
                resolved_target_project_root: None,
                error: Some(error),
            },
            EntryProfileState::Ready(profile) => Self {
                protocol: "swawkit.entry-profile-state/v2",
                revision,
                status: "ready",
                required_complete: true,
                path,
                resolved_target_project_root: Some(
                    profile
                        .binding()
                        .target_project_root()
                        .display()
                        .to_string(),
                ),
                profile: profile.record().clone(),
                error: None,
            },
        }
    }
}
