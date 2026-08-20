use std::error::Error;
use std::fmt;
use std::fs;
use std::os::windows::fs::MetadataExt;
use std::path::{Component, Path};

use swawkit_proj_protocol::{CommandIdentity, command_data_root};
use windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT;

use crate::catalog::CatalogSnapshot;

const LOCATOR_SEPARATOR: &str = "::";
const EXPORT_SCOPE: &str = "export";
const MAX_LOCATOR_BYTES: usize = 4 * 1024;
const MAX_RESOURCE_SEGMENTS: usize = 64;
const MAX_RESOURCE_SEGMENT_BYTES: usize = 255;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ResourceOutcome {
    ReadyDirectory,
    Missing,
    NotDirectory,
    Unsafe,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct ResourceInspection {
    locator: String,
    outcome: ResourceOutcome,
    diagnostic: Option<String>,
}

impl ResourceInspection {
    pub(super) fn canonical_locator(&self) -> &str {
        &self.locator
    }

    pub(super) fn locator(&self) -> &str {
        self.canonical_locator()
    }

    pub(super) fn outcome(&self) -> ResourceOutcome {
        self.outcome
    }

    pub(super) fn diagnostic(&self) -> Option<&str> {
        self.diagnostic.as_deref()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ResourceErrorKind {
    Arguments,
    Domain,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct ResourceError {
    kind: ResourceErrorKind,
    message: String,
}

impl ResourceError {
    pub(super) fn kind(&self) -> ResourceErrorKind {
        self.kind
    }

    fn arguments(message: impl Into<String>) -> Self {
        Self {
            kind: ResourceErrorKind::Arguments,
            message: message.into(),
        }
    }

    fn domain(message: impl Into<String>) -> Self {
        Self {
            kind: ResourceErrorKind::Domain,
            message: message.into(),
        }
    }
}

impl fmt::Display for ResourceError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl Error for ResourceError {}

pub(super) fn inspect_provider_export_directory(
    snapshot: &CatalogSnapshot,
    data_root: &Path,
    locator: &str,
) -> Result<ResourceInspection, ResourceError> {
    let locator = ProviderExportLocator::parse(locator)?;
    require_provider(snapshot, &locator.provider)?;
    let provider_root = command_data_root(data_root, &locator.provider);
    let mut target = provider_root.join(EXPORT_SCOPE);
    for segment in &locator.relative {
        target.push(segment);
    }
    Ok(inspect_directory(data_root, &target, locator.canonical))
}

struct ProviderExportLocator {
    provider: CommandIdentity,
    relative: Vec<String>,
    canonical: String,
}

impl ProviderExportLocator {
    fn parse(value: &str) -> Result<Self, ResourceError> {
        if value.is_empty() || value.len() > MAX_LOCATOR_BYTES || value.trim() != value {
            return Err(invalid_locator());
        }
        let Some((provider, resource)) = value.split_once(LOCATOR_SEPARATOR) else {
            return Err(invalid_locator());
        };
        if provider.is_empty() || resource.contains(LOCATOR_SEPARATOR) {
            return Err(invalid_locator());
        }
        let provider = CommandIdentity::parse(provider).map_err(|_| invalid_locator())?;
        let relative = match resource.strip_prefix("export/") {
            Some(relative) => parse_relative(relative)?,
            None if resource == EXPORT_SCOPE => Vec::new(),
            None => return Err(invalid_locator()),
        };
        let canonical = if relative.is_empty() {
            format!("{}{LOCATOR_SEPARATOR}{EXPORT_SCOPE}", provider.address())
        } else {
            format!(
                "{}{LOCATOR_SEPARATOR}{EXPORT_SCOPE}/{}",
                provider.address(),
                relative.join("/")
            )
        };
        if canonical != value {
            return Err(invalid_locator());
        }
        Ok(Self {
            provider,
            relative,
            canonical,
        })
    }
}

fn parse_relative(value: &str) -> Result<Vec<String>, ResourceError> {
    if value.is_empty()
        || value.len() > MAX_LOCATOR_BYTES
        || value.contains('\\')
        || Path::new(value).is_absolute()
    {
        return Err(invalid_locator());
    }
    let segments = value.split('/').collect::<Vec<_>>();
    if segments.is_empty() || segments.len() > MAX_RESOURCE_SEGMENTS {
        return Err(invalid_locator());
    }
    for segment in &segments {
        if segment.is_empty()
            || *segment == "."
            || *segment == ".."
            || segment.len() > MAX_RESOURCE_SEGMENT_BYTES
            || segment.ends_with(['.', ' '])
            || segment.chars().any(|character| {
                character.is_control()
                    || matches!(character, ':' | '<' | '>' | '"' | '|' | '?' | '*')
            })
        {
            return Err(invalid_locator());
        }
    }
    if !Path::new(value)
        .components()
        .all(|component| matches!(component, Component::Normal(_)))
    {
        return Err(invalid_locator());
    }
    Ok(segments.into_iter().map(str::to_owned).collect())
}

fn require_provider(
    snapshot: &CatalogSnapshot,
    identity: &CommandIdentity,
) -> Result<(), ResourceError> {
    let address = identity.address();
    let mut matches = snapshot
        .commands
        .iter()
        .filter(|command| command.address == address);
    let Some(provider) = matches.next() else {
        return Err(ResourceError::domain(format!(
            "provider command is absent from the Catalog: {address}"
        )));
    };
    if matches.next().is_some() {
        return Err(ResourceError::domain(format!(
            "provider command is ambiguous in the Catalog: {address}"
        )));
    }
    if provider.alias_of.is_some()
        || provider.space != identity.space()
        || provider.namespace.as_deref() != identity.namespace()
        || provider.path != identity.path()
    {
        return Err(ResourceError::domain(format!(
            "provider command is not canonical in the Catalog: {address}"
        )));
    }
    if !provider.runnable {
        return Err(ResourceError::domain(format!(
            "provider command is not runnable: {address}"
        )));
    }
    if provider
        .module
        .as_ref()
        .is_none_or(|module| module.provides.is_empty())
    {
        return Err(ResourceError::domain(format!(
            "provider command declares no exports: {address}"
        )));
    }
    Ok(())
}

fn inspect_directory(data_root: &Path, target: &Path, locator: String) -> ResourceInspection {
    if !data_root.is_absolute() {
        return unsafe_inspection(locator, "Entry DataRoot is not absolute");
    }
    let relative = match target.strip_prefix(data_root) {
        Ok(relative) => relative,
        Err(_) => {
            return unsafe_inspection(locator, "provider resource escaped Entry DataRoot");
        }
    };
    let mut current = data_root.to_path_buf();
    match inspect_member(&current) {
        MemberInspection::Directory => {}
        MemberInspection::Missing => {
            return unsafe_inspection(locator, "Entry DataRoot is missing");
        }
        MemberInspection::File | MemberInspection::Other => {
            return unsafe_inspection(locator, "Entry DataRoot is not a regular directory");
        }
        MemberInspection::Unsafe(message) => return unsafe_inspection(locator, message),
    }

    let components = relative.components().collect::<Vec<_>>();
    for (index, component) in components.iter().enumerate() {
        let Component::Normal(segment) = component else {
            return unsafe_inspection(locator, "provider resource path is not canonical");
        };
        current.push(segment);
        let leaf = index + 1 == components.len();
        match inspect_member(&current) {
            MemberInspection::Missing => {
                return inspection(locator, ResourceOutcome::Missing, None);
            }
            MemberInspection::Directory if leaf => {
                return inspection(locator, ResourceOutcome::ReadyDirectory, None);
            }
            MemberInspection::Directory => {}
            MemberInspection::File if leaf => {
                return inspection(
                    locator,
                    ResourceOutcome::NotDirectory,
                    Some("provider export resource is a regular file, not a directory".to_owned()),
                );
            }
            MemberInspection::File | MemberInspection::Other => {
                return unsafe_inspection(
                    locator,
                    "provider export resource has a non-directory ancestor or unsafe type",
                );
            }
            MemberInspection::Unsafe(message) => return unsafe_inspection(locator, message),
        }
    }
    unsafe_inspection(locator, "provider resource has no filesystem target")
}

enum MemberInspection {
    Missing,
    Directory,
    File,
    Other,
    Unsafe(String),
}

fn inspect_member(path: &Path) -> MemberInspection {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return MemberInspection::Missing;
        }
        Err(error) => {
            return MemberInspection::Unsafe(format!(
                "cannot inspect provider export resource: {error}"
            ));
        }
    };
    if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return MemberInspection::Unsafe(
            "provider export resource contains a reparse point".to_owned(),
        );
    }
    if metadata.is_dir() {
        MemberInspection::Directory
    } else if metadata.is_file() {
        MemberInspection::File
    } else {
        MemberInspection::Other
    }
}

fn inspection(
    locator: String,
    outcome: ResourceOutcome,
    diagnostic: Option<String>,
) -> ResourceInspection {
    ResourceInspection {
        locator,
        outcome,
        diagnostic,
    }
}

fn unsafe_inspection(locator: String, diagnostic: impl Into<String>) -> ResourceInspection {
    inspection(locator, ResourceOutcome::Unsafe, Some(diagnostic.into()))
}

fn invalid_locator() -> ResourceError {
    ResourceError::arguments(
        "resource locator must match '<canonical-provider>::export[/<safe-relative>]'",
    )
}

#[cfg(test)]
mod tests;
