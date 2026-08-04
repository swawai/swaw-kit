use std::error::Error;
use std::fmt;
use std::path::PathBuf;

use super::plan::DataRootPlan;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClaimKind {
    Current,
    Rename,
    MigrateLegacy,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DataRootClaim {
    pub kind: ClaimKind,
    pub entry_name: String,
    pub entry_file: PathBuf,
    pub volume_id: String,
    pub file_id: String,
    pub data_root: PathBuf,
    pub source_data_root: Option<PathBuf>,
    pub reason: String,
}

impl DataRootClaim {
    pub(crate) fn from_plan(plan: &DataRootPlan) -> Option<Self> {
        let (kind, source_data_root, reason) = match plan {
            DataRootPlan::ClaimCurrent { reason, .. } => (ClaimKind::Current, None, reason.clone()),
            DataRootPlan::ClaimRename {
                source_data_root,
                reason,
                ..
            } => (
                ClaimKind::Rename,
                Some(source_data_root.clone()),
                reason.clone(),
            ),
            DataRootPlan::ClaimMigrateLegacy {
                source_data_root,
                reason,
                ..
            } => (
                ClaimKind::MigrateLegacy,
                Some(source_data_root.clone()),
                reason.clone(),
            ),
            DataRootPlan::Direct { .. }
            | DataRootPlan::Create { .. }
            | DataRootPlan::MigrateLegacy { .. } => return None,
        };
        let target = plan.target();
        Some(Self {
            kind,
            entry_name: target.entry_name.clone(),
            entry_file: target.entry_file.clone(),
            volume_id: target.identity.volume_id().to_owned(),
            file_id: target.identity.file_id().to_owned(),
            data_root: target.data_root.clone(),
            source_data_root,
            reason,
        })
    }
}

pub trait DataRootClaimApprover {
    fn approve(&mut self, claim: &DataRootClaim) -> Result<bool, ClaimApprovalError>;
}

impl<F> DataRootClaimApprover for F
where
    F: FnMut(&DataRootClaim) -> Result<bool, ClaimApprovalError>,
{
    fn approve(&mut self, claim: &DataRootClaim) -> Result<bool, ClaimApprovalError> {
        self(claim)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClaimApprovalError {
    message: String,
}

impl ClaimApprovalError {
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl fmt::Display for ClaimApprovalError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl Error for ClaimApprovalError {}
