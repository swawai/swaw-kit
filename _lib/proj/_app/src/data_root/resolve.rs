use std::error::Error;
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};

use crate::entry::{EntryIdentity, EntryIdentityError};

use super::claim::{ClaimApprovalError, DataRootClaim, DataRootClaimApprover};
use super::development_environment::{
    DevelopmentEnvironmentRepair, DevelopmentEnvironmentRepairError, repair_development_environment,
};
use super::execute::{DataRootExecutionError, execute_plan};
use super::inventory::{DataRootInventory, DataRootInventoryError};
use super::lock::{DataRootLock, DataRootLockError};
use super::plan::{
    DataRootPlan, DataRootPlanError, DataRootPlanningRequest, ordinal_path_eq, ordinal_text_eq,
    plan_data_root,
};

pub struct ResolveDataRootRequest<'a> {
    pub swawkit_home: &'a Path,
    pub entry_file: &'a Path,
    pub inherited_data_root: Option<&'a Path>,
    pub legacy_data_directory: Option<&'a Path>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedDataRoot {
    pub path: PathBuf,
    pub development_environment_repair: DevelopmentEnvironmentRepair,
    pub warnings: Vec<String>,
}

pub fn resolve_data_root(
    request: ResolveDataRootRequest<'_>,
    approver: &mut impl DataRootClaimApprover,
) -> Result<ResolvedDataRoot, ResolveDataRootError> {
    let request = OwnedRequest::from_request(request)?;
    let data_directory = request.swawkit_home.join("data");

    let lock = DataRootLock::acquire(&data_directory)?;
    let initial_plan = build_plan(&request, &data_directory)?;
    let claim = DataRootClaim::from_plan(&initial_plan);
    let Some(claim) = claim else {
        return complete_locked(initial_plan, None, lock);
    };
    drop(lock);

    if !approver.approve(&claim)? {
        return Err(ResolveDataRootError::approval_denied());
    }

    let lock = DataRootLock::acquire(&data_directory)?;
    let current_plan = build_plan(&request, &data_directory)?;
    if !claim_state_stable(&initial_plan, &current_plan) {
        return Err(ResolveDataRootError::state_changed());
    }
    let completed_legacy_source = match &initial_plan {
        DataRootPlan::ClaimMigrateLegacy {
            source_data_root, ..
        } if matches!(current_plan, DataRootPlan::Direct { .. }) => Some(source_data_root.clone()),
        _ => None,
    };
    complete_locked(current_plan, completed_legacy_source, lock)
}

fn build_plan(
    request: &OwnedRequest,
    data_directory: &Path,
) -> Result<DataRootPlan, ResolveDataRootError> {
    let identity = EntryIdentity::read(&request.entry_file)?;
    let current = DataRootInventory::scan(data_directory)?;
    let legacy = request
        .legacy_data_directory
        .as_deref()
        .map(DataRootInventory::scan)
        .transpose()?;
    plan_data_root(DataRootPlanningRequest {
        entry_file: &request.entry_file,
        identity: &identity,
        current: &current,
        legacy: legacy.as_ref(),
        inherited_data_root: request.inherited_data_root.as_deref(),
    })
    .map_err(Into::into)
}

fn complete_locked(
    plan: DataRootPlan,
    completed_legacy_source: Option<PathBuf>,
    lock: DataRootLock,
) -> Result<ResolvedDataRoot, ResolveDataRootError> {
    let path = plan.target().data_root.clone();
    let entry_name = plan.target().entry_name.clone();
    let execution = execute_plan(&plan)?;
    let repair = repair_development_environment(&path)?;
    let mut warnings = Vec::new();
    if repair == DevelopmentEnvironmentRepair::RemovedStale {
        warnings.push(format!(
            concat!(
                "the development environment publication was moved or incomplete. ",
                "Run '{} .dev.setup' once to republish it."
            ),
            entry_name
        ));
    }
    if let Some(source) = execution.legacy_source.or(completed_legacy_source)
        && let Some(warning) = remove_legacy_residue(&source)
    {
        warnings.push(warning);
    }
    let resolved = ResolvedDataRoot {
        path,
        development_environment_repair: repair,
        warnings,
    };
    drop(lock);
    Ok(resolved)
}

fn claim_state_stable(initial: &DataRootPlan, current: &DataRootPlan) -> bool {
    let initial_target = initial.target();
    let current_target = current.target();
    if !ordinal_path_eq(&initial_target.entry_file, &current_target.entry_file)
        || !ordinal_path_eq(&initial_target.data_root, &current_target.data_root)
        || !ordinal_text_eq(&initial_target.entry_name, &current_target.entry_name)
        || initial_target.identity != current_target.identity
    {
        return false;
    }
    if matches!(current, DataRootPlan::Direct { .. }) {
        return true;
    }
    match (initial, current) {
        (DataRootPlan::ClaimCurrent { .. }, DataRootPlan::ClaimCurrent { .. }) => true,
        (
            DataRootPlan::ClaimRename {
                source_data_root: initial_source,
                ..
            },
            DataRootPlan::ClaimRename {
                source_data_root: current_source,
                ..
            },
        )
        | (
            DataRootPlan::ClaimMigrateLegacy {
                source_data_root: initial_source,
                ..
            },
            DataRootPlan::ClaimMigrateLegacy {
                source_data_root: current_source,
                ..
            },
        ) => ordinal_path_eq(initial_source, current_source),
        _ => false,
    }
}

fn remove_legacy_residue(legacy_data_root: &Path) -> Option<String> {
    let legacy_directory = legacy_data_root.parent()?;
    if !legacy_directory.is_dir() {
        return None;
    }
    let result = (|| -> Result<(), std::io::Error> {
        let lock_path = legacy_directory.join("_proj-entry.lock");
        if lock_path.is_file() && fs::metadata(&lock_path)?.len() == 0 {
            fs::remove_file(lock_path)?;
        }
        if fs::read_dir(legacy_directory)?
            .next()
            .transpose()?
            .is_none()
        {
            fs::remove_dir(legacy_directory)?;
        }
        Ok(())
    })();
    result.err().map(|error| {
        format!(
            "the obsolete project-local data directory could not be fully cleaned: {}. {error}",
            legacy_directory.display()
        )
    })
}

struct OwnedRequest {
    swawkit_home: PathBuf,
    entry_file: PathBuf,
    inherited_data_root: Option<PathBuf>,
    legacy_data_directory: Option<PathBuf>,
}

impl OwnedRequest {
    fn from_request(request: ResolveDataRootRequest<'_>) -> Result<Self, ResolveDataRootError> {
        let swawkit_home = required_directory(request.swawkit_home, "SWAWKIT_HOME")?;
        let entry_file = absolute(request.entry_file, "project entry file")?;
        let inherited_data_root = match request.inherited_data_root {
            Some(path) if !path.is_absolute() => {
                return Err(ResolveDataRootError::invalid_input(
                    "inherited SWAWKIT_PROJ_DATA_ROOT must be absolute".to_owned(),
                ));
            }
            Some(path) => Some(absolute(path, "inherited DataRoot")?),
            None => None,
        };
        let legacy_data_directory = request
            .legacy_data_directory
            .map(|path| absolute(path, "legacy project data directory"))
            .transpose()?;
        Ok(Self {
            swawkit_home,
            entry_file,
            inherited_data_root,
            legacy_data_directory,
        })
    }
}

fn required_directory(path: &Path, label: &str) -> Result<PathBuf, ResolveDataRootError> {
    let path = absolute(path, label)?;
    if !path.is_dir() {
        return Err(ResolveDataRootError::invalid_input(format!(
            "{label} does not exist: {}",
            path.display()
        )));
    }
    Ok(path)
}

fn absolute(path: &Path, label: &str) -> Result<PathBuf, ResolveDataRootError> {
    std::path::absolute(path).map_err(|error| {
        ResolveDataRootError::invalid_input(format!(
            "invalid {label} path '{}': {error}",
            path.display()
        ))
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ResolveDataRootErrorKind {
    ApprovalDenied,
    StateChanged,
    Other,
}

#[derive(Debug)]
pub struct ResolveDataRootError {
    kind: ResolveDataRootErrorKind,
    message: String,
}

impl ResolveDataRootError {
    fn invalid_input(message: String) -> Self {
        Self::other(message)
    }

    fn approval_denied() -> Self {
        Self {
            kind: ResolveDataRootErrorKind::ApprovalDenied,
            message: "project DataRoot claim was not approved".to_owned(),
        }
    }

    fn state_changed() -> Self {
        Self {
            kind: ResolveDataRootErrorKind::StateChanged,
            message: concat!(
                "project DataRoot state changed during claim. ",
                "Review it and retry the entry."
            )
            .to_owned(),
        }
    }

    fn other(message: String) -> Self {
        Self {
            kind: ResolveDataRootErrorKind::Other,
            message,
        }
    }

    pub fn is_approval_denied(&self) -> bool {
        self.kind == ResolveDataRootErrorKind::ApprovalDenied
    }

    pub fn is_state_changed(&self) -> bool {
        self.kind == ResolveDataRootErrorKind::StateChanged
    }
}

impl fmt::Display for ResolveDataRootError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl Error for ResolveDataRootError {}

macro_rules! resolve_error_from {
    ($error:ty) => {
        impl From<$error> for ResolveDataRootError {
            fn from(error: $error) -> Self {
                Self::other(error.to_string())
            }
        }
    };
}

resolve_error_from!(EntryIdentityError);
resolve_error_from!(DataRootInventoryError);
resolve_error_from!(DataRootPlanError);
resolve_error_from!(DataRootLockError);
resolve_error_from!(ClaimApprovalError);
resolve_error_from!(DataRootExecutionError);
resolve_error_from!(DevelopmentEnvironmentRepairError);

#[cfg(test)]
mod tests;
