use std::error::Error;
use std::fmt;

use crate::catalog::{CatalogSnapshot, CommandNode, CommandSource};

/// Renders the catalog-backed help shown by the CLI.
///
/// An empty `target_address` selects the kernel root. Non-root addresses must
/// identify exactly one catalog node.
pub fn render_help(
    snapshot: &CatalogSnapshot,
    target_address: &str,
) -> Result<String, HelpRenderError> {
    let target = find_target(snapshot, target_address)?;
    let document = match (&target.help_diagnostic, &target.help) {
        (Some(diagnostic), _) => {
            return Err(HelpRenderError::Invalid {
                address: target_address.to_owned(),
                diagnostic: diagnostic.clone(),
            });
        }
        (None, Some(document)) => document,
        (None, None) => {
            return Err(HelpRenderError::Unavailable(target_address.to_owned()));
        }
    };

    let mut sections = vec![document.text.trim_end().to_owned()];
    let children = direct_children(snapshot, target);
    if children.is_empty() {
        return Ok(sections.join("\n\n"));
    }

    if target_address.is_empty() {
        append_section(
            &mut sections,
            "Control Plane:",
            children
                .iter()
                .copied()
                .filter(|node| node.source == CommandSource::Control),
            snapshot,
        );
        append_section(
            &mut sections,
            "Kernel Commands:",
            children
                .iter()
                .copied()
                .filter(|node| node.source == CommandSource::Kernel),
            snapshot,
        );
        append_section(
            &mut sections,
            "Project Actions:",
            children
                .iter()
                .copied()
                .filter(|node| node.source == CommandSource::Action),
            snapshot,
        );
    } else {
        append_section(
            &mut sections,
            "Subcommands:",
            children.iter().copied(),
            snapshot,
        );
    }

    Ok(sections.join("\n\n"))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HelpRenderError {
    NotFound(String),
    Ambiguous(String),
    Unavailable(String),
    Invalid { address: String, diagnostic: String },
}

impl fmt::Display for HelpRenderError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotFound(address) => write!(formatter, "Help target not found: {address}"),
            Self::Ambiguous(address) => write!(formatter, "Ambiguous help target: {address}"),
            Self::Unavailable(address) => {
                write!(formatter, "Proj help is not enabled for '{address}'.")
            }
            Self::Invalid {
                address,
                diagnostic,
            } => write!(formatter, "Invalid Proj help for '{address}': {diagnostic}"),
        }
    }
}

impl Error for HelpRenderError {}

fn find_target<'a>(
    snapshot: &'a CatalogSnapshot,
    target_address: &str,
) -> Result<&'a CommandNode, HelpRenderError> {
    let mut matches = snapshot.commands.iter().filter(|node| {
        node.address == target_address
            && (!target_address.is_empty() || node.source == CommandSource::Kernel)
    });
    let Some(target) = matches.next() else {
        return Err(HelpRenderError::NotFound(target_address.to_owned()));
    };
    if matches.next().is_some() {
        return Err(HelpRenderError::Ambiguous(target_address.to_owned()));
    }
    Ok(target)
}

fn direct_children<'a>(
    snapshot: &'a CatalogSnapshot,
    target: &CommandNode,
) -> Vec<&'a CommandNode> {
    let include_all_sources = target.address.is_empty();
    let mut children: Vec<&CommandNode> = snapshot
        .commands
        .iter()
        .filter(|node| {
            node.alias_of.is_none()
                && node.parent.as_deref() == Some(target.address.as_str())
                && (include_all_sources || node.source == target.source)
        })
        .collect();
    children.sort_by(|left, right| left.address.cmp(&right.address));
    children
}

fn append_section<'a>(
    sections: &mut Vec<String>,
    heading: &str,
    nodes: impl Iterator<Item = &'a CommandNode>,
    snapshot: &CatalogSnapshot,
) {
    let rows: Vec<String> = nodes.map(|node| render_row(snapshot, node)).collect();
    if !rows.is_empty() {
        sections.push(format!("{heading}\n{}", rows.join("\n")));
    }
}

fn render_row(snapshot: &CatalogSnapshot, node: &CommandNode) -> String {
    let address = display_address(snapshot, node);
    let invocation = format!("{} {address}", snapshot.entry_name);
    format!("  {invocation:<34} {}", summary(node))
}

fn display_address(snapshot: &CatalogSnapshot, node: &CommandNode) -> String {
    let mut aliases: Vec<&str> = snapshot
        .commands
        .iter()
        .filter(|candidate| {
            candidate.source == node.source
                && candidate.alias_of.as_deref() == Some(node.address.as_str())
        })
        .map(|candidate| candidate.address.as_str())
        .collect();
    aliases.sort_by(|left, right| {
        alias_kind(left)
            .cmp(&alias_kind(right))
            .then_with(|| left.len().cmp(&right.len()))
            .then_with(|| left.cmp(right))
    });

    if aliases.is_empty() {
        node.address.clone()
    } else {
        format!("{} ({})", node.address, aliases.join(", "))
    }
}

fn alias_kind(alias: &str) -> u8 {
    if alias.starts_with('.') { 0 } else { 1 }
}

fn summary(node: &CommandNode) -> String {
    if let Some(diagnostic) = &node.help_diagnostic {
        return format!("[help protocol error] {diagnostic}");
    }
    if let Some(help) = &node.help {
        return help.summary.clone();
    }
    if let Some(diagnostic) = &node.diagnostic {
        return format!("[protocol error] {diagnostic}");
    }
    if node.runnable {
        return "[help handled by command]".to_owned();
    }
    "[command group; no Proj help]".to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::catalog::{CATALOG_PROTOCOL, HelpDocument};
    use std::path::PathBuf;

    #[test]
    fn renders_root_document_and_catalog_groups_without_alias_rows() {
        let snapshot = snapshot(vec![
            node("", CommandSource::Kernel, None, help("Root help")),
            node(
                "..entry",
                CommandSource::Control,
                Some(""),
                help("Entry profile"),
            ),
            node(".dev", CommandSource::Kernel, Some(""), help("Develop")),
            node(".dev.setup", CommandSource::Kernel, Some(".dev"), None),
            node(".help", CommandSource::Kernel, Some(""), help("Show help")),
            alias(".h", ".help"),
            alias("-h", ".help"),
            alias("--help", ".help"),
            node("build", CommandSource::Action, Some(""), help("Build")),
        ]);

        let output = render_help(&snapshot, "").expect("root help");

        assert!(output.starts_with("Root help\n\nControl Plane:"));
        assert!(output.contains("swawkit ..entry"));
        assert!(output.contains("Kernel Commands:\n  swawkit .dev"));
        assert!(output.contains("swawkit .help (.h, -h, --help)"));
        assert!(!output.contains("swawkit .dev.setup"));
        assert!(
            !output
                .lines()
                .any(|line| line.trim_start().starts_with("swawkit .h "))
        );
        assert!(output.contains("Project Actions:\n  swawkit build"));
    }

    #[test]
    fn renders_only_same_source_direct_subcommands_with_catalog_fallbacks() {
        let mut group = node(
            ".dev",
            CommandSource::Kernel,
            Some(""),
            help("Development commands"),
        );
        group.help.as_mut().expect("help").text = "Detailed development help\n".into();

        let mut status = node(".dev.status", CommandSource::Kernel, Some(".dev"), None);
        status.runnable = true;
        let mut broken = node(".dev.broken", CommandSource::Kernel, Some(".dev"), None);
        broken.diagnostic = Some("multiple run entries".into());
        let snapshot = snapshot(vec![
            node("", CommandSource::Kernel, None, help("Root")),
            group,
            status,
            broken,
            node(
                ".dev.nested",
                CommandSource::Action,
                Some(".dev"),
                help("Other source"),
            ),
        ]);

        let output = render_help(&snapshot, ".dev").expect("group help");

        assert!(output.starts_with("Detailed development help\n\nSubcommands:"));
        assert!(output.contains("[protocol error] multiple run entries"));
        assert!(output.contains("[help handled by command]"));
        assert!(!output.contains("Other source"));
    }

    #[test]
    fn rejects_missing_ambiguous_unopted_and_invalid_targets() {
        let mut invalid = node("invalid", CommandSource::Action, Some(""), None);
        invalid.help = help("must not render");
        invalid.help_diagnostic = Some("help file is empty".into());
        let snapshot = snapshot(vec![
            node("", CommandSource::Kernel, None, help("Root")),
            node("same", CommandSource::Kernel, Some(""), help("Kernel")),
            node("same", CommandSource::Action, Some(""), help("Action")),
            node("plain", CommandSource::Action, Some(""), None),
            invalid,
        ]);

        assert_eq!(
            render_help(&snapshot, "missing"),
            Err(HelpRenderError::NotFound("missing".into()))
        );
        assert_eq!(
            render_help(&snapshot, "same"),
            Err(HelpRenderError::Ambiguous("same".into()))
        );
        assert_eq!(
            render_help(&snapshot, "plain"),
            Err(HelpRenderError::Unavailable("plain".into()))
        );
        assert_eq!(
            render_help(&snapshot, "invalid"),
            Err(HelpRenderError::Invalid {
                address: "invalid".into(),
                diagnostic: "help file is empty".into(),
            })
        );
    }

    fn snapshot(commands: Vec<CommandNode>) -> CatalogSnapshot {
        CatalogSnapshot {
            protocol: CATALOG_PROTOCOL,
            entry_name: "swawkit".into(),
            commands,
        }
    }

    fn alias(address: &str, target: &str) -> CommandNode {
        let mut node = node(address, CommandSource::Kernel, Some(""), None);
        node.alias_of = Some(target.into());
        node
    }

    fn help(summary: &str) -> Option<HelpDocument> {
        Some(HelpDocument {
            summary: summary.into(),
            text: summary.into(),
        })
    }

    fn node(
        address: &str,
        source: CommandSource,
        parent: Option<&str>,
        help: Option<HelpDocument>,
    ) -> CommandNode {
        CommandNode {
            address: address.into(),
            source,
            parent: parent.map(str::to_owned),
            alias_of: None,
            runnable: false,
            entry: None,
            adapter: None,
            handler: None,
            help,
            view: None,
            diagnostic: None,
            help_diagnostic: None,
            directory: PathBuf::new(),
        }
    }
}
