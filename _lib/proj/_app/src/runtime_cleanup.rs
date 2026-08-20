use serde::{Deserialize, Serialize};
use std::io::Write;

use crate::{context::EntryContext, runtime_cleanup_engine};

pub const RUNTIME_CLEANUP_PROTOCOL: &str = "swawkit.runtime-cleanup/v1";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RuntimeCleanupAction {
    Preview,
    Apply,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RuntimeCleanupState {
    Selected,
    InUse,
    Removable,
    Removed,
    Retained,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RuntimeCleanupItem {
    pub release_id: String,
    pub state: RuntimeCleanupState,
    pub pids: Vec<u32>,
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RuntimeCleanupSummary {
    pub selected: usize,
    pub in_use: usize,
    pub removable: usize,
    pub removed: usize,
    pub retained: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RuntimeCleanupDocument {
    pub protocol: String,
    pub action: RuntimeCleanupAction,
    pub items: Vec<RuntimeCleanupItem>,
    pub summary: RuntimeCleanupSummary,
}

impl RuntimeCleanupDocument {
    pub fn new(action: RuntimeCleanupAction, items: Vec<RuntimeCleanupItem>) -> Self {
        let mut summary = RuntimeCleanupSummary::default();
        for item in &items {
            match item.state {
                RuntimeCleanupState::Selected => summary.selected += 1,
                RuntimeCleanupState::InUse => summary.in_use += 1,
                RuntimeCleanupState::Removable => summary.removable += 1,
                RuntimeCleanupState::Removed => summary.removed += 1,
                RuntimeCleanupState::Retained => summary.retained += 1,
            }
        }
        Self {
            protocol: RUNTIME_CLEANUP_PROTOCOL.to_owned(),
            action,
            items,
            summary,
        }
    }

    pub fn render_text(&self) -> String {
        let mut output = format!(
            "Runtime Release cleanup {}",
            match self.action {
                RuntimeCleanupAction::Preview => "preview",
                RuntimeCleanupAction::Apply => "apply",
            }
        );
        for item in &self.items {
            output.push('\n');
            match item.state {
                RuntimeCleanupState::Selected => {
                    output.push_str(&format!("[SELECTED] {}", item.release_id));
                }
                RuntimeCleanupState::InUse => {
                    let pids = item
                        .pids
                        .iter()
                        .map(u32::to_string)
                        .collect::<Vec<_>>()
                        .join(",");
                    output.push_str(&format!("[IN USE] {} PID {pids}", item.release_id));
                }
                RuntimeCleanupState::Removable => {
                    output.push_str(&format!("[REMOVABLE] {}", item.release_id));
                }
                RuntimeCleanupState::Removed => {
                    output.push_str(&format!("[REMOVED] {}", item.release_id));
                }
                RuntimeCleanupState::Retained => {
                    output.push_str(&format!(
                        "[RETAINED] {}: {}",
                        item.release_id,
                        item.reason.as_deref().unwrap_or("unknown reason")
                    ));
                }
            }
        }
        output.push_str(&format!(
            "\nSummary: selected={}, in-use={}, removable={}, removed={}, retained={}",
            self.summary.selected,
            self.summary.in_use,
            self.summary.removable,
            self.summary.removed,
            self.summary.retained,
        ));
        if self.action == RuntimeCleanupAction::Preview && self.summary.removable > 0 {
            output.push_str("\nRun again with --apply to delete the removable Releases.");
        }
        output
    }
}

pub fn execute_text(context: &EntryContext, apply: bool) -> Result<i32, String> {
    let document = runtime_cleanup_engine::run(context, apply)?;
    println!("{}", document.render_text());
    Ok(0)
}

pub fn execute_json(context: &EntryContext, apply: bool) -> Result<RuntimeCleanupDocument, String> {
    runtime_cleanup_engine::run(context, apply)
}

pub fn write_json(
    document: &RuntimeCleanupDocument,
    output: &mut impl Write,
) -> Result<(), String> {
    serde_json::to_writer(&mut *output, document)
        .map_err(|error| format!("cannot serialize Runtime cleanup document: {error}"))?;
    output
        .write_all(b"\n")
        .map_err(|error| format!("cannot write Runtime cleanup document: {error}"))
}

#[cfg(test)]
mod tests;
