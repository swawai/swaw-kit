use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use crate::error::{ContextError, ContextResult};
use crate::model::{CommandSpace, ContextRecord};
use crate::runtime::Language;

const MODULE_SCHEMA: &str = "swawkit.command-module/v9";
const MODULE_CONTRACT: &str = include_str!("../../swawkit.module.json");
const SUBJECT_COLLECTION_PROTOCOL: &str = "swawkit.subject-collection/v3";
const CONTEXT_KIND: &str = "context";

pub(crate) fn render_markdown(record: &ContextRecord) -> String {
    let mut lines = vec![
        format!("# Context: {}", record.id),
        String::new(),
        format!("Subject: `::context/{}`", record.id),
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

pub(crate) fn subject_collection(
    language: Language,
    records: Vec<ContextRecord>,
) -> ContextResult<SubjectCollection> {
    let facet_ids = context_facet_ids()?;
    let subjects = records
        .into_iter()
        .map(|record| SubjectSummary {
            reference: SubjectRef::Instance {
                kind: CONTEXT_KIND.to_owned(),
                id: record.id.clone(),
            },
            label: format!("::{CONTEXT_KIND}/{}", record.id),
            summary: match language {
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
            },
            facet_ids: facet_ids.clone(),
        })
        .collect();
    Ok(SubjectCollection {
        protocol: SUBJECT_COLLECTION_PROTOCOL.to_owned(),
        owner: SubjectRef::Command {
            space: CommandSpace::Module,
            namespace: Some("swaw".to_owned()),
            address: "swaw/context".to_owned(),
        },
        facet: "contexts".to_owned(),
        subjects,
    })
}

fn context_facet_ids() -> ContextResult<Vec<String>> {
    let contract: ModuleContract = serde_json::from_str(MODULE_CONTRACT).map_err(|error| {
        ContextError::new(format!("invalid embedded Context module contract: {error}"))
    })?;
    if contract.schema != MODULE_SCHEMA {
        return Err(ContextError::new(format!(
            "unsupported Context module contract schema '{}'",
            contract.schema
        )));
    }
    let kind = contract
        .subject_kinds
        .iter()
        .find(|kind| kind.kind == CONTEXT_KIND)
        .ok_or_else(|| ContextError::new("Context Subject kind is unavailable"))?;
    let mut unique = BTreeSet::new();
    let facet_ids = kind
        .facets
        .iter()
        .map(|facet| facet.id.clone())
        .collect::<Vec<_>>();
    if facet_ids.is_empty() || facet_ids.iter().any(|id| !unique.insert(id.clone())) {
        return Err(ContextError::new(
            "Context Subject facets must be non-empty and unique",
        ));
    }
    Ok(facet_ids)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ModuleContract {
    schema: String,
    #[serde(default)]
    subject_kinds: Vec<SubjectKindContract>,
}

#[derive(Deserialize)]
struct SubjectKindContract {
    kind: String,
    facets: Vec<FacetContract>,
}

#[derive(Deserialize)]
struct FacetContract {
    id: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SubjectCollection {
    protocol: String,
    owner: SubjectRef,
    facet: String,
    subjects: Vec<SubjectSummary>,
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "lowercase")]
enum SubjectRef {
    Command {
        space: CommandSpace,
        #[serde(skip_serializing_if = "Option::is_none")]
        namespace: Option<String>,
        address: String,
    },
    Instance {
        kind: String,
        id: String,
    },
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct SubjectSummary {
    #[serde(rename = "ref")]
    reference: SubjectRef,
    label: String,
    summary: String,
    facet_ids: Vec<String>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{CONTEXT_SCHEMA, ContextCommand};

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
    fn markdown_is_deterministic_and_uses_the_context_subject_address() {
        let output = render_markdown(&record());
        assert!(
            output.starts_with("# Context: release-check\n\nSubject: `::context/release-check`")
        );
        assert!(output.contains("- `.dev/status` (system)"));
        assert!(output.ends_with("## Final Prompt\n\nContinue."));
    }

    #[test]
    fn collection_facets_come_from_the_embedded_domain_manifest() {
        let collection = subject_collection(Language::En, vec![record()]).unwrap();
        let value = serde_json::to_value(collection).unwrap();
        assert_eq!(value["protocol"], SUBJECT_COLLECTION_PROTOCOL);
        assert_eq!(value["subjects"][0]["ref"]["id"], "release-check");
        assert!(
            value["subjects"][0]["facetIds"]
                .as_array()
                .unwrap()
                .contains(&serde_json::json!("overview"))
        );
    }
}
