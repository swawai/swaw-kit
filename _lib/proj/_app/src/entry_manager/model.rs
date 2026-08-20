use serde::{Deserialize, Serialize};

pub const ENTRY_INVENTORY_PROTOCOL: &str = "swawkit.entry-inventory/v1";
pub const ENTRY_INSTANCE_STATE_PROTOCOL: &str = "swawkit.entry-instance-state/v1";
pub const ENTRY_INSTANCE_MUTATION_PROTOCOL: &str = "swawkit.entry-instance-mutation/v1";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum EntryStatus {
    Available,
    Ready,
    LegacyMigrationRequired,
    Incomplete,
    Conflict,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EntryState {
    pub entry_name: String,
    pub entry_file: String,
    pub data_root: String,
    pub status: EntryStatus,
    pub entry_id: Option<String>,
    pub release_id: Option<String>,
    pub issues: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EntryInventoryDocument {
    pub protocol: String,
    pub swawkit_home: String,
    pub entries: Vec<EntryState>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EntryInstanceStateDocument {
    pub protocol: String,
    pub entry: EntryState,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum EntryMutationOperation {
    Create,
    Migrate,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EntryMutationDocument {
    pub protocol: String,
    pub operation: EntryMutationOperation,
    pub changed: bool,
    pub entry: EntryState,
}
