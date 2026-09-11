use std::collections::BTreeMap;

use serde::Serialize;

use super::{EntryConfigRecord, EntryConfigState, LANGUAGE_ADDRESS, PROJECT_ROOT_ADDRESS};

pub const ENTRY_CONFIG_DOCUMENT_PROTOCOL: &str = "swawkit.entry-config-state/v1";

/// Transport-neutral representation shared by the CLI and Web API.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EntryConfigDocument {
    pub protocol: &'static str,
    pub revision: String,
    pub status: &'static str,
    pub path: String,
    pub config: EntryConfigRecord,
    pub settings: BTreeMap<&'static str, Option<String>>,
    pub resolved_project_root: Option<String>,
    pub error: Option<String>,
}

impl EntryConfigDocument {
    pub(super) fn from_state(state: EntryConfigState, path: String, revision: String) -> Self {
        match state {
            EntryConfigState::Default { .. } => Self::new(
                "default",
                path,
                revision,
                EntryConfigRecord::default(),
                None,
                None,
            ),
            EntryConfigState::Invalid { error, .. } => Self::new(
                "invalid",
                path,
                revision,
                EntryConfigRecord::default(),
                None,
                Some(error),
            ),
            EntryConfigState::Ready(config) => {
                let resolved = config
                    .binding()
                    .map(|binding| binding.project_root().display().to_string());
                let status = if config.binding_error().is_some() {
                    "bindingUnavailable"
                } else {
                    "ready"
                };
                Self::new(
                    status,
                    path,
                    revision,
                    config.record().clone(),
                    resolved,
                    config.binding_error().map(str::to_owned),
                )
            }
        }
    }

    fn new(
        status: &'static str,
        path: String,
        revision: String,
        config: EntryConfigRecord,
        resolved_project_root: Option<String>,
        error: Option<String>,
    ) -> Self {
        let settings = BTreeMap::from([
            (LANGUAGE_ADDRESS, Some(config.language.clone())),
            (PROJECT_ROOT_ADDRESS, config.project_root.clone()),
        ]);
        Self {
            protocol: ENTRY_CONFIG_DOCUMENT_PROTOCOL,
            revision,
            status,
            path,
            config,
            settings,
            resolved_project_root,
            error,
        }
    }
}
