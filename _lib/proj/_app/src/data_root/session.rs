use crate::entry::EntryId;

use super::{ResolveDataRootError, ResolveDataRootRequest, ResolvedDataRoot, resolve_data_root};

#[derive(Clone)]
pub struct DataRootSession {
    resolved: ResolvedDataRoot,
}

impl DataRootSession {
    pub fn new(request: ResolveDataRootRequest<'_>) -> Result<Self, ResolveDataRootError> {
        Ok(Self {
            resolved: resolve_data_root(request)?,
        })
    }

    pub fn resolved(&self) -> ResolvedDataRoot {
        self.resolved.clone()
    }

    pub fn entry_id(&self) -> &EntryId {
        self.resolved.entry_id()
    }
}
