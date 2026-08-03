use std::io;

use crate::{catalog::CatalogSnapshot, context::AppContext};

#[derive(Debug, Clone)]
pub struct CatalogReader {
    context: AppContext,
}

impl CatalogReader {
    pub fn new(context: AppContext) -> Self {
        Self { context }
    }

    pub async fn read(&self) -> io::Result<CatalogSnapshot> {
        let context = self.context.clone();
        tokio::task::spawn_blocking(move || CatalogSnapshot::discover(&context))
            .await
            .map_err(|error| io::Error::other(format!("catalog worker failed: {error}")))?
    }
}
