use swawkit_proj_protocol::{
    FacetExecutionManifest, FacetRequirementsManifest, ResourceExportsManifest, ResourceFacetKind,
    ResourceKindManifest, WebViewSource, parse_facet_execution_manifest,
    parse_facet_requirements_manifest, parse_resource_exports_manifest,
    parse_resource_kind_manifest, parse_web_view_source,
};

use super::{
    EXECUTION_FILE, EXPORTS_FILE, Loader, REQUIREMENTS_FILE, RESOURCE_KIND_FILE, VIEW_DIRECTORY,
    WEB_VIEW_FILE,
    filesystem::{self, DirectorySnapshot, EntryKind},
};

impl Loader {
    pub(super) fn load_exports(
        &mut self,
        snapshot: &DirectorySnapshot,
    ) -> Option<ResourceExportsManifest> {
        let bytes = self.protocol_file(snapshot, EXPORTS_FILE, false)?;
        match parse_resource_exports_manifest(&bytes) {
            Ok(exports) => Some(exports),
            Err(error) => {
                self.report(snapshot.path.join(EXPORTS_FILE), error);
                None
            }
        }
    }

    pub(super) fn load_execution(
        &mut self,
        snapshot: &DirectorySnapshot,
    ) -> Option<FacetExecutionManifest> {
        let bytes = self.protocol_file(snapshot, EXECUTION_FILE, false)?;
        match parse_facet_execution_manifest(&bytes) {
            Ok(execution) => Some(execution),
            Err(error) => {
                self.report(snapshot.path.join(EXECUTION_FILE), error);
                None
            }
        }
    }

    pub(super) fn load_local_entry(&mut self, snapshot: &DirectorySnapshot) -> Option<String> {
        const LOCAL_ENTRIES: [&str; 5] = ["run.exe", "run.ts", "run.py", "run.ps1", "run.cmd"];
        let mut entries = Vec::new();
        for expected in LOCAL_ENTRIES {
            let matches = snapshot
                .entries
                .iter()
                .filter(|entry| entry.name.eq_ignore_ascii_case(expected))
                .collect::<Vec<_>>();
            if matches.len() > 1 {
                self.report(
                    &snapshot.path,
                    format!("local Facet entry name collision for '{expected}'"),
                );
                return None;
            }
            let Some(entry) = matches.first() else {
                continue;
            };
            if entry.name != expected {
                self.report(
                    &entry.path,
                    format!("non-canonical local Facet entry; expected '{expected}'"),
                );
                return None;
            }
            if entry.kind != EntryKind::File || entry.reparse_point {
                self.report(&entry.path, "local Facet entry must be a plain file");
                return None;
            }
            entries.push(expected.to_owned());
        }
        if entries.len() > 1 {
            self.report(
                &snapshot.path,
                "Operation Facet contains multiple local run.* entries",
            );
            return None;
        }
        let entry = entries.pop()?;
        Some(entry)
    }

    pub(super) fn load_requirements(
        &self,
        snapshot: &DirectorySnapshot,
    ) -> Result<Option<FacetRequirementsManifest>, String> {
        snapshot
            .protocol_file(REQUIREMENTS_FILE, false)?
            .map(|bytes| parse_facet_requirements_manifest(&bytes))
            .transpose()
            .map_err(|error| error.to_string())
    }

    pub(super) fn load_resource_kind(
        &mut self,
        snapshot: &DirectorySnapshot,
        kind: ResourceFacetKind,
    ) -> Option<ResourceKindManifest> {
        let bytes = self.protocol_file(snapshot, RESOURCE_KIND_FILE, false)?;
        if kind != ResourceFacetKind::Collection {
            self.report(
                snapshot.path.join(RESOURCE_KIND_FILE),
                "only a Collection Facet may declare a Resource Kind",
            );
            return None;
        }
        match parse_resource_kind_manifest(&bytes) {
            Ok(resource_kind) => Some(resource_kind),
            Err(error) => {
                self.report(snapshot.path.join(RESOURCE_KIND_FILE), error);
                None
            }
        }
    }

    pub(super) fn load_view(
        &mut self,
        snapshot: &DirectorySnapshot,
        kind: ResourceFacetKind,
    ) -> Option<WebViewSource> {
        let view = self.view_directory(snapshot)?;
        if kind != ResourceFacetKind::Collection {
            self.report(
                &view.path,
                "first-slice Web View is only valid for a Collection Facet",
            );
            return None;
        }
        let view_snapshot = self.open(&view.path)?;
        let bytes = self.protocol_file(&view_snapshot, WEB_VIEW_FILE, true)?;
        match parse_web_view_source(&bytes) {
            Ok(view) => Some(view),
            Err(error) => {
                self.report(view.path.join(WEB_VIEW_FILE), error);
                None
            }
        }
    }

    pub(super) fn view_directory<'a>(
        &mut self,
        snapshot: &'a DirectorySnapshot,
    ) -> Option<&'a filesystem::SafeEntry> {
        match snapshot.named_directory(VIEW_DIRECTORY) {
            Ok(view) => view,
            Err(error) => {
                self.report(&snapshot.path, error);
                None
            }
        }
    }
}
