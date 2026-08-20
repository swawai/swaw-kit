use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use super::*;

pub(crate) struct ProviderInvalidation {
    state_path: PathBuf,
    previous: Option<Vec<u8>>,
    committed: bool,
    _state_lock: ExclusiveFileLock,
}

impl ProviderInvalidation {
    pub(crate) fn commit(mut self) {
        self.committed = true;
    }

    pub(crate) fn rollback(mut self) -> Result<(), String> {
        let result = self.restore();
        if result.is_ok() {
            self.committed = true;
        }
        result
    }

    fn restore(&self) -> Result<(), String> {
        regular_file_or_missing(&self.state_path, "command provider state")
            .map_err(|error| error.to_string())?;
        match &self.previous {
            Some(content) => atomic_file::publish(&self.state_path, content)
                .map_err(|error| format!("cannot restore command provider state: {error}")),
            None => match fs::remove_file(&self.state_path) {
                Ok(()) => Ok(()),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(error) => Err(format!("cannot remove command provider state: {error}")),
            },
        }
    }
}

impl Drop for ProviderInvalidation {
    fn drop(&mut self) {
        if !self.committed {
            let _ = self.restore();
        }
    }
}

pub(crate) fn begin_unavailable(
    data_root: &Path,
    input_revision: &str,
) -> Result<ProviderInvalidation, String> {
    require_revision(input_revision, "Dev Settings input revision")?;
    migrate_legacy_layout(data_root)?;
    let setup = ensure_directory_chain(
        data_root,
        &["modules", "system", "dev", "setup"],
        "development setup provider",
    )
    .map_err(|error| error.to_string())?;
    let locks = ensure_directory_chain(
        data_root,
        &["modules", "system", "dev", "setup", "locks"],
        "development setup locks",
    )
    .map_err(|error| error.to_string())?;
    let state_path = setup.join("_state.json");
    let state_lock = ExclusiveFileLock::acquire(&locks.join("state.lock"), Duration::from_secs(60))
        .map_err(|error| format!("cannot acquire development provider state lock: {error}"))?;
    let previous = if regular_file_or_missing(&state_path, "command provider state")
        .map_err(|error| error.to_string())?
    {
        Some(
            read_replaceable_bounded(&state_path, "command provider state", MAX_STATE_BYTES)
                .map_err(|error| error.to_string())?,
        )
    } else {
        None
    };
    write_state(
        &state_path,
        &ProviderState {
            schema: STATE_SCHEMA.to_owned(),
            status: "unavailable".to_owned(),
            input_revision: input_revision.to_owned(),
            token: fresh_token()?,
        },
    )?;
    Ok(ProviderInvalidation {
        state_path,
        previous,
        committed: false,
        _state_lock: state_lock,
    })
}
