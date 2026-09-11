use serde::Deserialize;
use swawkit_proj_protocol::{FacetRoute, ResourceIdentity, ResourceList, ResourceListing};

use crate::error::{ContextError, ContextResult};
use crate::model::ContextRecord;
use crate::runtime::Language;

const FACET_SCHEMA: &str = "swawkit.facet/v1";
const CONTEXT_KIND_ROUTE: &str = "$/system::context/contexts";
const CONTEXT_FACETS: [(&str, &str); 7] = [
    (
        "overview",
        include_str!("../contexts/overview/swawkit.facet.json"),
    ),
    (
        "render",
        include_str!("../contexts/render/swawkit.facet.json"),
    ),
    ("add", include_str!("../contexts/add/swawkit.facet.json")),
    (
        "remove",
        include_str!("../contexts/remove/swawkit.facet.json"),
    ),
    ("note", include_str!("../contexts/note/swawkit.facet.json")),
    (
        "prompt",
        include_str!("../contexts/prompt/swawkit.facet.json"),
    ),
    (
        "delete",
        include_str!("../contexts/delete/swawkit.facet.json"),
    ),
];

pub(crate) fn render_markdown(record: &ContextRecord) -> String {
    let mut lines = vec![
        format!("# Context: {}", record.id),
        String::new(),
        format!("Resource: `$/system::context/contexts::{}`", record.id),
        String::new(),
        "## Commands".to_owned(),
        String::new(),
    ];
    if record.commands.is_empty() {
        lines.push("_None._".to_owned());
    } else {
        lines.extend(record.commands.iter().map(|command| {
            let identity = command
                .namespace
                .as_deref()
                .unwrap_or_else(|| command.space.as_str());
            format!("- `{}` ({identity})", command.address)
        }));
    }
    lines.extend([String::new(), "## Notes".to_owned(), String::new()]);
    if record.notes.is_empty() {
        lines.push("_None._".to_owned());
    } else {
        for (index, note) in record.notes.iter().enumerate() {
            if index > 0 {
                lines.push(String::new());
            }
            lines.extend([
                format!("### Note {}", index + 1),
                String::new(),
                note.clone(),
            ]);
        }
    }
    lines.extend([
        String::new(),
        "## Final Prompt".to_owned(),
        String::new(),
        if record.prompt.is_empty() {
            "_None._".to_owned()
        } else {
            record.prompt.clone()
        },
    ]);
    lines.join("\n")
}

pub(crate) fn resource_list(
    language: Language,
    records: Vec<ContextRecord>,
) -> ContextResult<ResourceList> {
    let source = FacetRoute::parse(CONTEXT_KIND_ROUTE).map_err(protocol_error)?;
    let facet_ids = context_facet_ids()?;
    let resources = records
        .into_iter()
        .map(|record| {
            let route = source
                .resource()
                .child(source.facet(), &record.id)
                .map_err(protocol_error)?;
            let summary = match language {
                Language::ZhCn => format!(
                    "{} 个命令 · {} 条说明",
                    record.commands.len(),
                    record.notes.len()
                ),
                Language::En => format!(
                    "{} commands · {} notes",
                    record.commands.len(),
                    record.notes.len()
                ),
            };
            ResourceListing::new(
                ResourceIdentity::instance(source.clone(), record.id.clone())
                    .map_err(protocol_error)?,
                record.id.clone(),
                route,
                facet_ids.clone(),
                record.id,
                summary,
            )
            .map_err(protocol_error)
        })
        .collect::<ContextResult<Vec<_>>>()?;
    ResourceList::new(source, resources).map_err(protocol_error)
}

fn context_facet_ids() -> ContextResult<Vec<String>> {
    let mut facet_ids = Vec::with_capacity(CONTEXT_FACETS.len());
    for (id, source) in CONTEXT_FACETS {
        let manifest: FacetManifest = serde_json::from_str(source).map_err(|error| {
            ContextError::new(format!("invalid embedded Context Facet '{id}': {error}"))
        })?;
        if manifest.schema != FACET_SCHEMA || manifest.kind == "collection" {
            return Err(ContextError::new(format!(
                "Context Facet '{id}' must be a current operation or projection"
            )));
        }
        facet_ids.push(id.to_owned());
    }
    Ok(facet_ids)
}

fn protocol_error(error: impl std::fmt::Display) -> ContextError {
    ContextError::new(error.to_string())
}

#[derive(Deserialize)]
struct FacetManifest {
    schema: String,
    kind: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{CONTEXT_SCHEMA, CommandSpace, ContextCommand};

    fn record() -> ContextRecord {
        ContextRecord {
            schema: CONTEXT_SCHEMA.to_owned(),
            id: "release-check".to_owned(),
            commands: vec![ContextCommand {
                space: CommandSpace::System,
                namespace: None,
                address: ".dev/status".to_owned(),
            }],
            notes: vec!["Inspect first.".to_owned()],
            prompt: "Continue.".to_owned(),
        }
    }

    #[test]
    fn markdown_uses_the_canonical_context_resource_route() {
        let output = render_markdown(&record());
        assert!(output.starts_with(
            "# Context: release-check\n\nResource: `$/system::context/contexts::release-check`"
        ));
        assert!(output.contains("- `.dev/status` (system)"));
        assert!(output.ends_with("## Final Prompt\n\nContinue."));
    }

    #[test]
    fn resource_grants_come_from_the_embedded_facet_declarations() {
        let list = resource_list(Language::En, vec![record()]).unwrap();
        let value = serde_json::to_value(list).unwrap();
        assert_eq!(value["protocol"], "swawkit.resource-list/v2");
        assert_eq!(value["resources"][0]["identity"]["id"], "release-check");
        assert!(
            value["resources"][0]["facetIds"]
                .as_array()
                .unwrap()
                .contains(&serde_json::json!("overview"))
        );
    }
}
