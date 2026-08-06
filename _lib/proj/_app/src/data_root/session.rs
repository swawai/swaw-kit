use std::error::Error;
use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

use super::{
    ClaimApprovalError, DataRootClaim, ResolveDataRootError, ResolveDataRootRequest,
    ResolvedDataRoot, claim_data_root, inspect_data_root, resolve_data_root,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DataRootSessionState {
    Ready(ResolvedDataRoot),
    ClaimRequired(DataRootClaim),
}

#[derive(Clone)]
pub struct DataRootSession {
    request: Arc<SessionRequest>,
    ready: Arc<Mutex<Option<ResolvedDataRoot>>>,
}

impl DataRootSession {
    pub fn new(request: ResolveDataRootRequest<'_>) -> Self {
        Self {
            request: Arc::new(SessionRequest::from_request(request)),
            ready: Arc::new(Mutex::new(None)),
        }
    }

    pub fn status(&self) -> Result<DataRootSessionState, DataRootSessionError> {
        let mut ready = self.lock_ready()?;
        if let Some(resolved) = ready.as_ref() {
            return Ok(DataRootSessionState::Ready(resolved.clone()));
        }

        let inspection = inspect_data_root(self.request.borrow())?;
        if let Some(claim) = inspection.claim {
            return Ok(DataRootSessionState::ClaimRequired(claim));
        }

        let resolved = self.resolve_without_claim()?;
        *ready = Some(resolved.clone());
        Ok(DataRootSessionState::Ready(resolved))
    }

    pub fn claim(
        &self,
        expected_revision: &str,
        confirmation: &str,
    ) -> Result<Vec<String>, DataRootSessionError> {
        let mut ready = self.lock_ready()?;
        if let Some(resolved) = ready.as_ref() {
            return Ok(resolved.warnings.clone());
        }

        let inspection = inspect_data_root(self.request.borrow())?;
        let Some(expected_claim) = inspection.claim else {
            let resolved = self.resolve_without_claim()?;
            let warnings = resolved.warnings.clone();
            *ready = Some(resolved);
            return Ok(warnings);
        };
        if expected_claim.revision() != expected_revision {
            return Err(DataRootSessionError::Conflict);
        }
        if confirmation != expected_claim.entry_name {
            return Err(DataRootSessionError::ConfirmationMismatch {
                expected: expected_claim.entry_name,
            });
        }

        let resolved = match claim_data_root(self.request.borrow(), &expected_claim) {
            Ok(resolved) => resolved,
            Err(error) if error.is_state_changed() => {
                return Err(DataRootSessionError::Conflict);
            }
            Err(error) => return Err(error.into()),
        };
        let warnings = resolved.warnings.clone();
        *ready = Some(resolved);
        Ok(warnings)
    }

    fn resolve_without_claim(&self) -> Result<ResolvedDataRoot, DataRootSessionError> {
        let mut saw_claim = false;
        let result = {
            let mut reject = |_claim: &DataRootClaim| {
                saw_claim = true;
                Err(ClaimApprovalError::new("DataRoot claim is required"))
            };
            resolve_data_root(self.request.borrow(), &mut reject)
        };
        if saw_claim {
            return Err(DataRootSessionError::Conflict);
        }
        result.map_err(Into::into)
    }

    fn lock_ready(
        &self,
    ) -> Result<MutexGuard<'_, Option<ResolvedDataRoot>>, DataRootSessionError> {
        self.ready
            .lock()
            .map_err(|_| DataRootSessionError::Unavailable)
    }
}

struct SessionRequest {
    swawkit_home: PathBuf,
    entry_file: PathBuf,
    inherited_data_root: Option<PathBuf>,
    legacy_data_directory: Option<PathBuf>,
}

impl SessionRequest {
    fn from_request(request: ResolveDataRootRequest<'_>) -> Self {
        Self {
            swawkit_home: request.swawkit_home.to_path_buf(),
            entry_file: request.entry_file.to_path_buf(),
            inherited_data_root: request.inherited_data_root.map(Path::to_path_buf),
            legacy_data_directory: request.legacy_data_directory.map(Path::to_path_buf),
        }
    }

    fn borrow(&self) -> ResolveDataRootRequest<'_> {
        ResolveDataRootRequest {
            swawkit_home: &self.swawkit_home,
            entry_file: &self.entry_file,
            inherited_data_root: self.inherited_data_root.as_deref(),
            legacy_data_directory: self.legacy_data_directory.as_deref(),
        }
    }
}

#[derive(Debug)]
pub enum DataRootSessionError {
    ConfirmationMismatch { expected: String },
    Conflict,
    Resolution(ResolveDataRootError),
    Unavailable,
}

impl fmt::Display for DataRootSessionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::ConfirmationMismatch { expected } => write!(
                formatter,
                "DataRoot confirmation must exactly match '{expected}'"
            ),
            Self::Conflict => formatter.write_str(
                "DataRoot claim state changed; reload the current claim before confirming",
            ),
            Self::Resolution(error) => error.fmt(formatter),
            Self::Unavailable => formatter.write_str("DataRoot session is unavailable"),
        }
    }
}

impl Error for DataRootSessionError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Resolution(error) => Some(error),
            _ => None,
        }
    }
}

impl From<ResolveDataRootError> for DataRootSessionError {
    fn from(error: ResolveDataRootError) -> Self {
        Self::Resolution(error)
    }
}
