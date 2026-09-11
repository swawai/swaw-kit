use std::io;

use crate::{catalog::CatalogSnapshot, context::EntryContext, entry_config::EntryConfigStore};

#[derive(Debug, Clone)]
pub struct CatalogReader {
    context: EntryContext,
    config_store: EntryConfigStore,
}

impl CatalogReader {
    pub fn new(context: EntryContext, config_store: EntryConfigStore) -> Self {
        Self {
            context,
            config_store,
        }
    }

    pub async fn read(&self) -> io::Result<CatalogSnapshot> {
        let context = self.context.clone();
        let config_store = self.config_store.clone();
        tokio::task::spawn_blocking(move || {
            let state = config_store.read();
            CatalogSnapshot::discover(&context, state.ready())
        })
        .await
        .map_err(|error| io::Error::other(format!("catalog worker failed: {error}")))?
    }
}
