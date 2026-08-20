use std::ffi::OsString;
use std::path::Path;

use serde::Serialize;

use crate::catalog::CatalogSnapshot;

use super::resource::{
    ResourceError, ResourceErrorKind, ResourceInspection, ResourceOutcome,
    inspect_provider_export_directory,
};
use super::{CoreCommandError, CoreCommandOutcome, require_core_command};

pub(super) const DIRECTORY_EXISTS_ADDRESS: &str = ".check/dir/exists";
const DIRECTORY_EXISTS_HANDLER: &str = "meta.check.dir.exists";
const DIRECTORY_EXISTS_PROTOCOL: &str = "swawkit.check.dir-exists/v1";

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct DirectoryExistsDocument {
    protocol: &'static str,
    resource: String,
    ready: bool,
    status: &'static str,
    message: Option<String>,
}

pub(super) fn execute(
    snapshot: &CatalogSnapshot,
    argv: &[OsString],
    data_root: &Path,
) -> Result<CoreCommandOutcome, CoreCommandError> {
    require_core_command(snapshot, DIRECTORY_EXISTS_ADDRESS, DIRECTORY_EXISTS_HANDLER)?;
    let (locator, json) = match argv {
        [_, locator] => (unicode(locator, "resource locator")?, false),
        [_, locator, format] if format == "--json" => (unicode(locator, "resource locator")?, true),
        _ => return Err(usage()),
    };
    let inspection =
        inspect_provider_export_directory(snapshot, data_root, locator).map_err(resource_error)?;
    let document = document(inspection);
    let output = if json {
        serde_json::to_string_pretty(&document).map_err(|error| {
            CoreCommandError::serialization("cannot serialize directory check", error)
        })?
    } else {
        render_text(&document)
    };
    Ok(CoreCommandOutcome::with_exit_code(
        if document.ready { 0 } else { 1 },
        format!("{output}\n"),
    ))
}

fn document(inspection: ResourceInspection) -> DirectoryExistsDocument {
    let (ready, status) = match inspection.outcome() {
        ResourceOutcome::ReadyDirectory => (true, "ready"),
        ResourceOutcome::Missing => (false, "missing"),
        ResourceOutcome::NotDirectory => (false, "not-directory"),
        ResourceOutcome::Unsafe => (false, "unsafe"),
    };
    DirectoryExistsDocument {
        protocol: DIRECTORY_EXISTS_PROTOCOL,
        resource: inspection.locator().to_owned(),
        ready,
        status,
        message: inspection.diagnostic().map(str::to_owned),
    }
}

fn render_text(document: &DirectoryExistsDocument) -> String {
    let mut lines = vec![
        format!("Resource: {}", document.resource),
        format!("Ready: {}", if document.ready { "yes" } else { "no" }),
        format!("Status: {}", document.status),
    ];
    if let Some(message) = &document.message {
        lines.push(format!("Message: {message}"));
    }
    lines.join("\n")
}

fn resource_error(error: ResourceError) -> CoreCommandError {
    match error.kind() {
        ResourceErrorKind::Arguments => CoreCommandError::arguments(error.to_string()),
        ResourceErrorKind::Domain => CoreCommandError::domain(error.to_string()),
    }
}

fn unicode<'a>(value: &'a OsString, label: &str) -> Result<&'a str, CoreCommandError> {
    value
        .to_str()
        .ok_or_else(|| CoreCommandError::arguments(format!("{label} is not valid Unicode")))
}

fn usage() -> CoreCommandError {
    CoreCommandError::arguments("usage: .check/dir/exists <provider>::export[/<path>] [--json]")
}

#[cfg(test)]
mod tests;
