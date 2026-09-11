mod command;
mod filesystem;
mod metadata;
mod model;
mod projection;

#[cfg(test)]
mod tests;

use std::path::Path;

use swawkit_proj_protocol::{
    FacetRoute, ResourceFacetKind, ResourceKindManifest, ResourceRoute,
    parse_resource_facet_manifest, parse_resource_manifest,
};

use filesystem::DirectorySnapshot;
use model::{FacetTemplate, LoadedFacet, LoadedResource, ResourceDiagnostic, ResourceLoad};

pub(super) use command::{has_resource_marker, load_command_resource};
pub(super) use projection::{command_identity_for_resource_route, resource_route_for_command};

const RESOURCE_FILE: &str = "swawkit.resource.json";
const FACET_FILE: &str = "swawkit.facet.json";
const EXECUTION_FILE: &str = "swawkit.execution.json";
const REQUIREMENTS_FILE: &str = "swawkit.requirements.json";
const EXPORTS_FILE: &str = "swawkit.exports.json";
const RESOURCE_KIND_FILE: &str = "swawkit.resource-kind.json";
const VIEW_DIRECTORY: &str = "view";
const WEB_VIEW_FILE: &str = "web.json";

fn load_resource_tree(root: &Path, route: ResourceRoute) -> ResourceLoad {
    let selector = root
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("root")
        .to_owned();
    let mut loader = Loader::default();
    let resource = loader.load_resource(root, route, selector);
    ResourceLoad {
        resource,
        diagnostics: loader.diagnostics,
    }
}

#[derive(Default)]
struct Loader {
    diagnostics: Vec<ResourceDiagnostic>,
}

impl Loader {
    fn load_resource(
        &mut self,
        directory: &Path,
        route: ResourceRoute,
        selector: String,
    ) -> Option<LoadedResource> {
        let snapshot = self.open(directory)?;
        let bytes = self.protocol_file(&snapshot, RESOURCE_FILE, true)?;
        let manifest = match parse_resource_manifest(&bytes) {
            Ok(manifest) => manifest,
            Err(error) => {
                self.report(directory.join(RESOURCE_FILE), error);
                return None;
            }
        };

        let exports = self.load_exports(&snapshot);
        let facets = snapshot
            .directories()
            .filter_map(|entry| {
                let child = self.open(&entry.path)?;
                if self.has_protocol_file(&child, FACET_FILE) != Some(true) {
                    return None;
                }
                let facet = match FacetRoute::new(route.clone(), entry.name.clone()) {
                    Ok(facet) => facet,
                    Err(error) => {
                        self.report(&entry.path, error);
                        return None;
                    }
                };
                self.load_facet(&entry.path, facet)
            })
            .collect();

        Some(LoadedResource {
            route,
            selector,
            kind: manifest.kind,
            directory: directory.to_path_buf(),
            exports,
            facets,
        })
    }

    fn load_facet(&mut self, directory: &Path, route: FacetRoute) -> Option<LoadedFacet> {
        let snapshot = self.open(directory)?;
        let bytes = self.protocol_file(&snapshot, FACET_FILE, true)?;
        let manifest = match parse_resource_facet_manifest(&bytes) {
            Ok(manifest) => manifest,
            Err(error) => {
                self.report(directory.join(FACET_FILE), error);
                return None;
            }
        };

        let mut execution = self.load_execution(&snapshot);
        let mut local_entry = self.load_local_entry(&snapshot);
        let mut requirements = match self.load_requirements(&snapshot) {
            Ok(requirements) => requirements,
            Err(error) => {
                self.report(directory.join(REQUIREMENTS_FILE), error);
                return None;
            }
        };
        if execution.is_some() && local_entry.is_some() {
            self.report(
                directory,
                "Facet declares both a local run.* entry and swawkit.execution.json",
            );
            execution = None;
            local_entry = None;
        }
        if requirements.is_some() && execution.is_none() && local_entry.is_none() {
            self.report(
                directory.join(REQUIREMENTS_FILE),
                "Facet Requirements need one valid executable implementation",
            );
            requirements = None;
        }
        let mut resource_kind = self.load_resource_kind(&snapshot, manifest.kind);
        let view = self.load_view(&snapshot, manifest.kind);
        let mut resources = Vec::new();
        let mut templates = Vec::new();

        for entry in snapshot
            .directories()
            .filter(|entry| entry.name != VIEW_DIRECTORY)
        {
            if manifest.kind != ResourceFacetKind::Collection {
                self.report(
                    &entry.path,
                    "only a Collection Facet may contain Resource members",
                );
                continue;
            }
            let Some(child) = self.open(&entry.path) else {
                continue;
            };
            let has_resource = self.has_protocol_file(&child, RESOURCE_FILE);
            let has_facet = self.has_protocol_file(&child, FACET_FILE);
            match (has_resource, has_facet, resource_kind.as_ref()) {
                (Some(true), Some(false), _) => {
                    if matches!(
                        resource_kind.as_ref(),
                        Some(ResourceKindManifest::Reference(_))
                    ) {
                        self.report(
                            &entry.path,
                            "a referenced Resource Kind cannot contain local Resource members",
                        );
                        continue;
                    }
                    let child_route = match route.resource().child(route.facet(), &entry.name) {
                        Ok(reference) => reference,
                        Err(error) => {
                            self.report(&entry.path, error);
                            continue;
                        }
                    };
                    if let Some(resource) =
                        self.load_resource(&entry.path, child_route, entry.name.clone())
                    {
                        resources.push(resource);
                    }
                }
                (Some(false), Some(true), Some(ResourceKindManifest::Definition(_))) => {
                    if let Some(template) = self.load_template(&entry.path, &entry.name) {
                        templates.push(template);
                    }
                }
                (Some(false), Some(false), _) => self.report(
                    &entry.path,
                    "Collection child must contain swawkit.resource.json",
                ),
                (Some(true), Some(true), _) => self.report(
                    &entry.path,
                    "Collection child cannot be both a Resource and a Facet template",
                ),
                (Some(false), Some(true), Some(ResourceKindManifest::Reference(_))) => self.report(
                    &entry.path,
                    "a referenced Resource Kind cannot declare local Facet templates",
                ),
                (Some(false), Some(true), None) => self.report(
                    &entry.path,
                    "Facet templates require swawkit.resource-kind.json on the Collection",
                ),
                _ => {}
            }
        }

        if manifest.kind == ResourceFacetKind::Collection {
            let implementation_sources = usize::from(!resources.is_empty())
                + usize::from(execution.is_some() || local_entry.is_some());
            if implementation_sources > 1 {
                self.report(
                    directory,
                    "Collection Facet declares more than one implementation source",
                );
                execution = None;
                local_entry = None;
                resource_kind = None;
                resources.clear();
                templates.clear();
            }
        }

        Some(LoadedFacet {
            route,
            kind: manifest.kind,
            presentation: manifest.presentation,
            directory: directory.to_path_buf(),
            local_entry,
            execution,
            requirements,
            view,
            resource_kind,
            resources,
            templates,
        })
    }

    fn load_template(&mut self, directory: &Path, id: &str) -> Option<FacetTemplate> {
        let placeholder = FacetRoute::new(ResourceRoute::root(), id.to_owned());
        let route = match placeholder {
            Ok(route) => route,
            Err(error) => {
                self.report(directory, error);
                return None;
            }
        };
        let snapshot = self.open(directory)?;
        let bytes = self.protocol_file(&snapshot, FACET_FILE, true)?;
        let manifest = match parse_resource_facet_manifest(&bytes) {
            Ok(manifest) => manifest,
            Err(error) => {
                self.report(directory.join(FACET_FILE), error);
                return None;
            }
        };
        if manifest.kind == ResourceFacetKind::Collection {
            self.report(
                directory,
                "nested dynamic Collection templates are not supported",
            );
            return None;
        }
        let mut execution = self.load_execution(&snapshot);
        let mut local_entry = self.load_local_entry(&snapshot);
        let mut requirements = match self.load_requirements(&snapshot) {
            Ok(requirements) => requirements,
            Err(error) => {
                self.report(directory.join(REQUIREMENTS_FILE), error);
                return None;
            }
        };
        if execution.is_some() && local_entry.is_some() {
            self.report(
                directory,
                "Facet template declares both a local run.* entry and swawkit.execution.json",
            );
            execution = None;
            local_entry = None;
        }
        if requirements.is_some() && execution.is_none() && local_entry.is_none() {
            self.report(
                directory.join(REQUIREMENTS_FILE),
                "Facet template Requirements need one valid executable implementation",
            );
            requirements = None;
        }
        if self.has_protocol_file(&snapshot, RESOURCE_KIND_FILE) == Some(true) {
            self.report(
                directory.join(RESOURCE_KIND_FILE),
                "a dynamic Facet template cannot declare a Resource Kind",
            );
        }
        let view = self.load_view(&snapshot, manifest.kind);
        for entry in snapshot
            .directories()
            .filter(|entry| entry.name != VIEW_DIRECTORY)
        {
            self.report(
                &entry.path,
                "a dynamic Facet template cannot contain child directories",
            );
        }
        Some(FacetTemplate {
            id: route.facet().to_owned(),
            kind: manifest.kind,
            presentation: manifest.presentation,
            directory: directory.to_path_buf(),
            local_entry,
            execution,
            requirements,
            view,
        })
    }

    fn open(&mut self, directory: &Path) -> Option<DirectorySnapshot> {
        match DirectorySnapshot::open(directory) {
            Ok(snapshot) => Some(snapshot),
            Err(error) => {
                self.report(directory, error);
                None
            }
        }
    }

    fn protocol_file(
        &mut self,
        snapshot: &DirectorySnapshot,
        name: &str,
        required: bool,
    ) -> Option<Vec<u8>> {
        match snapshot.protocol_file(name, required) {
            Ok(bytes) => bytes,
            Err(error) => {
                self.report(&snapshot.path, error);
                None
            }
        }
    }

    fn has_protocol_file(&mut self, snapshot: &DirectorySnapshot, name: &str) -> Option<bool> {
        snapshot
            .protocol_file(name, false)
            .map(|bytes| bytes.is_some())
            .map_err(|error| self.report(&snapshot.path, error))
            .ok()
    }

    fn report(&mut self, path: impl AsRef<Path>, message: impl ToString) {
        self.diagnostics.push(ResourceDiagnostic {
            path: path.as_ref().to_path_buf(),
            message: message.to_string(),
        });
    }
}
