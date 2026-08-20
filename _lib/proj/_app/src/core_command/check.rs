use std::ffi::OsString;
use std::path::Path;

use crate::catalog::{CatalogSnapshot, CommandSpace};
use crate::command_check::{CommandCheckDocument, DependencyCheck, inspect};
use crate::context::EntryContext;

use super::{CoreCommandError, CoreCommandOutcome};

const CHECK_ADDRESS: &str = ".check";

pub fn is_invocation(argv: &[OsString]) -> bool {
    argv.first().is_some_and(|address| address == CHECK_ADDRESS)
}

pub fn execute(
    snapshot: &CatalogSnapshot,
    argv: &[OsString],
    context: &EntryContext,
    data_root: &Path,
) -> Result<Option<CoreCommandOutcome>, CoreCommandError> {
    let Some(address) = argv.first().and_then(|value| value.to_str()) else {
        return Ok(None);
    };
    if address != CHECK_ADDRESS {
        return Ok(None);
    }
    require_check_command(snapshot)?;
    let (target, json) = match argv {
        [_, target] => (unicode(target, "command address")?, false),
        [_, target, format] if format == "--json" => (unicode(target, "command address")?, true),
        _ => return Err(check_usage()),
    };
    let document = inspect(data_root, &context.entry_name, snapshot, target)
        .map_err(CoreCommandError::domain)?;
    let output = if json {
        serde_json::to_string_pretty(&document).map_err(|error| {
            CoreCommandError::serialization("cannot serialize command check", error)
        })?
    } else {
        render_text(&document)
    };
    Ok(Some(CoreCommandOutcome::with_exit_code(
        if document.ready { 0 } else { 1 },
        format!("{output}\n"),
    )))
}

fn require_check_command(snapshot: &CatalogSnapshot) -> Result<(), CoreCommandError> {
    if snapshot.commands.iter().any(|command| {
        command.space == CommandSpace::System
            && command.address == CHECK_ADDRESS
            && command.adapter.as_deref() == Some("core")
            && command.handler.as_deref() == Some("meta.check")
            && command.runnable
    }) {
        Ok(())
    } else {
        Err(CoreCommandError::domain("command not found: .check"))
    }
}

fn render_text(document: &CommandCheckDocument) -> String {
    let mut lines = vec![
        format!("Command: {}", document.command.address),
        format!("Ready: {}", yes_no(document.ready)),
        format!("Runnable: {}", yes_no(document.command.runnable)),
        format!(
            "Adapter: {}",
            document.command.adapter.as_deref().unwrap_or("none")
        ),
    ];
    if let Some(diagnostic) = &document.command.diagnostic {
        lines.push(format!("Diagnostic: {diagnostic}"));
    }

    lines.push(String::new());
    lines.push("Dependencies:".to_owned());
    if document.dependencies.is_empty() {
        lines.push("  none declared".to_owned());
    } else {
        for dependency in &document.dependencies {
            append_dependency(&mut lines, dependency, 1);
        }
    }

    lines.join("\n")
}

fn append_dependency(lines: &mut Vec<String>, dependency: &DependencyCheck, depth: usize) {
    let indent = "  ".repeat(depth);
    lines.push(format!(
        "{indent}{} {}#{} [{}]",
        marker(dependency.ready),
        dependency.provider,
        dependency.export,
        dependency.contract
    ));
    if let Some(message) = &dependency.message {
        lines.push(format!("{indent}  {message}"));
    }
    for child in &dependency.dependencies {
        append_dependency(lines, child, depth + 1);
    }
}

fn marker(ready: bool) -> &'static str {
    if ready { "[READY]" } else { "[BLOCKED]" }
}

fn yes_no(value: bool) -> &'static str {
    if value { "yes" } else { "no" }
}

fn unicode<'a>(value: &'a OsString, label: &str) -> Result<&'a str, CoreCommandError> {
    value
        .to_str()
        .ok_or_else(|| CoreCommandError::arguments(format!("{label} is not valid Unicode")))
}

fn check_usage() -> CoreCommandError {
    CoreCommandError::arguments("usage: .check <command-address> [--json]")
}

#[cfg(test)]
mod tests;
