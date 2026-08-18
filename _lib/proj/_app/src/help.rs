use std::error::Error;
use std::fmt;

use crate::catalog::{CatalogSnapshot, CommandNode, CommandSpace};

/// Renders the catalog-backed help shown by the CLI.
///
/// An empty `target_address` selects the System root. Non-root addresses must
/// identify exactly one catalog node.
pub fn render_help(
    snapshot: &CatalogSnapshot,
    target_address: &str,
) -> Result<String, HelpRenderError> {
    let labels = HelpLabels::for_language(snapshot.language);
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
            labels.system_commands,
            children
                .iter()
                .copied()
                .filter(|node| node.space == CommandSpace::System),
            snapshot,
        );
        append_section(
            &mut sections,
            labels.modules,
            snapshot
                .commands
                .iter()
                .filter(|node| node.space == CommandSpace::Module && node.path.is_empty()),
            snapshot,
        );
    } else {
        append_section(
            &mut sections,
            labels.subcommands,
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
    let mut matches = snapshot
        .commands
        .iter()
        .filter(|node| node.address == target_address);
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
    let mut children: Vec<&CommandNode> = snapshot
        .commands
        .iter()
        .filter(|node| {
            node.alias_of.is_none() && node.parent.as_deref() == Some(target.address.as_str())
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
    format!("  {invocation:<34} {}", summary(snapshot, node))
}

fn display_address(_snapshot: &CatalogSnapshot, node: &CommandNode) -> String {
    node.address.clone()
}

fn summary(snapshot: &CatalogSnapshot, node: &CommandNode) -> String {
    let labels = HelpLabels::for_language(snapshot.language);
    if let Some(diagnostic) = &node.help_diagnostic {
        return format!("[{}] {diagnostic}", labels.help_protocol_error);
    }
    if let Some(help) = &node.help {
        return help.summary.clone();
    }
    if let Some(diagnostic) = &node.diagnostic {
        return format!("[{}] {diagnostic}", labels.protocol_error);
    }
    if node.runnable {
        return format!("[{}]", labels.help_handled_by_command);
    }
    format!("[{}]", labels.command_group_without_help)
}

struct HelpLabels {
    system_commands: &'static str,
    modules: &'static str,
    subcommands: &'static str,
    help_protocol_error: &'static str,
    protocol_error: &'static str,
    help_handled_by_command: &'static str,
    command_group_without_help: &'static str,
}

impl HelpLabels {
    fn for_language(language: &str) -> Self {
        if language == "en" {
            Self {
                system_commands: "System Commands:",
                modules: "Modules:",
                subcommands: "Subcommands:",
                help_protocol_error: "help protocol error",
                protocol_error: "protocol error",
                help_handled_by_command: "help handled by command",
                command_group_without_help: "command group; no Proj help",
            }
        } else {
            Self {
                system_commands: "系统命令：",
                modules: "模块：",
                subcommands: "子命令：",
                help_protocol_error: "帮助协议错误",
                protocol_error: "协议错误",
                help_handled_by_command: "帮助由命令自身处理",
                command_group_without_help: "命令组；没有 Proj 帮助",
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::catalog::{CATALOG_PROTOCOL, HelpDocument};
    use std::path::PathBuf;

    #[test]
    fn root_help_lists_system_commands_and_module_namespaces() {
        let snapshot = snapshot(vec![
            node("", CommandSpace::System, None, &[], None, help("Root")),
            node(
                ".help",
                CommandSpace::System,
                None,
                &["help"],
                Some(""),
                help("Help"),
            ),
            node(
                "swaw",
                CommandSpace::Module,
                Some("swaw"),
                &[],
                None,
                help("Official modules"),
            ),
            node(
                "swaw/context",
                CommandSpace::Module,
                Some("swaw"),
                &["context"],
                Some("swaw"),
                help("Contexts"),
            ),
        ]);

        let output = render_help(&snapshot, "").unwrap();
        assert!(output.contains("System Commands:"));
        assert!(output.contains("swawkit .help"));
        assert!(output.contains("Modules:"));
        assert!(output.contains("swawkit swaw"));
        assert!(!output.contains("swawkit swaw/context"));
    }

    #[test]
    fn non_root_help_lists_only_direct_children() {
        let snapshot = snapshot(vec![
            node(
                ".dev",
                CommandSpace::System,
                None,
                &["dev"],
                Some(""),
                help("Development"),
            ),
            node(
                ".dev/setup",
                CommandSpace::System,
                None,
                &["dev", "setup"],
                Some(".dev"),
                help("Setup"),
            ),
        ]);

        let output = render_help(&snapshot, ".dev").unwrap();
        assert!(output.contains("Subcommands:"));
        assert!(output.contains("swawkit .dev/setup"));
    }

    #[test]
    fn lookup_is_exact_and_does_not_accept_internal_space_prefixes() {
        let snapshot = snapshot(vec![node(
            "project/build",
            CommandSpace::Module,
            Some("project"),
            &["build"],
            Some("project"),
            help("Build"),
        )]);
        assert!(render_help(&snapshot, "project/build").is_ok());
        assert_eq!(
            render_help(&snapshot, "module/project/build"),
            Err(HelpRenderError::NotFound("module/project/build".to_owned()))
        );
    }

    fn snapshot(commands: Vec<CommandNode>) -> CatalogSnapshot {
        CatalogSnapshot {
            protocol: CATALOG_PROTOCOL,
            entry_name: "swawkit".to_owned(),
            language: "en",
            commands,
        }
    }

    fn help(summary: &str) -> Option<HelpDocument> {
        Some(HelpDocument {
            summary: summary.to_owned(),
            text: summary.to_owned(),
        })
    }

    fn node(
        address: &str,
        space: CommandSpace,
        namespace: Option<&str>,
        path: &[&str],
        parent: Option<&str>,
        help: Option<HelpDocument>,
    ) -> CommandNode {
        CommandNode {
            address: address.to_owned(),
            space,
            namespace: namespace.map(str::to_owned),
            path: path.iter().map(|segment| (*segment).to_owned()).collect(),
            parent: parent.map(str::to_owned),
            alias_of: None,
            runnable: false,
            entry: None,
            adapter: None,
            handler: None,
            module: None,
            help,
            subject_kinds: Vec::new(),
            facets: Vec::new(),
            view: None,
            diagnostic: None,
            help_diagnostic: None,
            directory: PathBuf::new(),
            native_owner: None,
        }
    }
}
