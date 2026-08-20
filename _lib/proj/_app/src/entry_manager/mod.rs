//! Manager-owned lifecycle for explicitly created Entry instances.

mod error;
mod inspect;
mod inventory;
mod launcher;
mod legacy;
mod model;
mod mutation;
mod name;
mod target_lease;

use crate::context::EntryContext;

pub use error::{EntryManagerError, EntryManagerErrorKind};
pub use model::{
    ENTRY_INSTANCE_MUTATION_PROTOCOL, ENTRY_INSTANCE_STATE_PROTOCOL, ENTRY_INVENTORY_PROTOCOL,
    EntryInstanceStateDocument, EntryInventoryDocument, EntryMutationDocument,
    EntryMutationOperation, EntryState, EntryStatus,
};
use name::EntryTarget;

pub struct EntryManager<'a> {
    pub(crate) context: &'a EntryContext,
}

impl<'a> EntryManager<'a> {
    pub fn new(context: &'a EntryContext) -> Self {
        Self { context }
    }

    pub fn inspect(&self, name: &str) -> Result<EntryInstanceStateDocument, EntryManagerError> {
        self.require_manager()?;
        let target = EntryTarget::parse(self.context, name)?;
        Ok(EntryInstanceStateDocument {
            protocol: ENTRY_INSTANCE_STATE_PROTOCOL.to_owned(),
            entry: inspect::inspect_target(&target)?,
        })
    }

    pub fn inventory(&self) -> Result<EntryInventoryDocument, EntryManagerError> {
        self.require_manager()?;
        let home = self.context.swawkit_home.to_str().ok_or_else(|| {
            EntryManagerError::corrupt("SWAWKIT_HOME is not a valid Unicode path")
        })?;
        Ok(EntryInventoryDocument {
            protocol: ENTRY_INVENTORY_PROTOCOL.to_owned(),
            swawkit_home: home.to_owned(),
            entries: inventory::read_inventory(self)?,
        })
    }

    pub fn create(&self, name: &str) -> Result<EntryMutationDocument, EntryManagerError> {
        self.require_manager()?;
        mutation::create(self, EntryTarget::parse(self.context, name)?)
    }

    pub fn migrate(&self, name: &str) -> Result<EntryMutationDocument, EntryManagerError> {
        self.require_manager()?;
        mutation::migrate(self, EntryTarget::parse(self.context, name)?)
    }

    fn require_manager(&self) -> Result<(), EntryManagerError> {
        if self.context.is_manager() {
            Ok(())
        } else {
            Err(EntryManagerError::new(
                EntryManagerErrorKind::ManagerOnly,
                "Entry lifecycle operations are restricted to the swawkit manager Entry",
            ))
        }
    }
}

#[cfg(test)]
mod tests;
