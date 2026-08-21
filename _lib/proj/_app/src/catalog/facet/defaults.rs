use crate::{
    command_check::COMMAND_CHECK_PROTOCOL,
    entry_config::EntryLanguage,
    facet::{Facet, FacetKind, FacetRenderer, FacetResolver},
};

use super::{CHECK_ADDRESS, CommandNode, HELP_ADDRESS};

pub(super) fn subcommands_facet(language: EntryLanguage) -> Facet {
    Facet {
        id: "subcommands".to_owned(),
        kind: FacetKind::Collection,
        renderer: FacetRenderer::Collection,
        icon: "□".to_owned(),
        label: text(language, "子命令", "Subcommands").to_owned(),
        summary: text(language, "浏览静态子命令", "Browse static subcommands").to_owned(),
        resource_kind: None,
        resolver: Some(FacetResolver::Catalog {
            relation: "subcommands".to_owned(),
        }),
        view: None,
    }
}

pub(super) fn default_facets(
    command: &CommandNode,
    language: EntryLanguage,
    help_available: bool,
    check_available: bool,
) -> Vec<Facet> {
    let mut facets = Vec::new();
    if command.handler.as_deref() == Some("entry.config.set") {
        facets.push(operation_facet(
            "edit",
            FacetRenderer::Edit,
            "*",
            text(language, "设置", "Setting"),
            text(
                language,
                "修改并保存配置值",
                "Edit and save a configuration value",
            ),
            command_resolver(&command.address, [], false),
        ));
    }
    if help_available {
        let arguments = if command.address.is_empty() {
            Vec::new()
        } else {
            vec![command.address.clone()]
        };
        facets.push(operation_facet(
            "help",
            FacetRenderer::Help,
            "?",
            text(language, "帮助", "Help"),
            text(language, "阅读命令说明", "Read command help"),
            FacetResolver::Command {
                address: HELP_ADDRESS.to_owned(),
                arguments,
                accepts_tail: false,
                confirmation: None,
                returns: None,
            },
        ));
    }
    if check_available
        && !command.is_control()
        && !command.address.is_empty()
        && command.alias_of.is_none()
        && (command.authored_resource || command.entry.is_some() || command.diagnostic.is_some())
    {
        facets.push(Facet {
            id: "check".to_owned(),
            kind: FacetKind::Projection,
            renderer: FacetRenderer::Overview,
            icon: "!".to_owned(),
            label: text(language, "检查", "Check").to_owned(),
            summary: text(
                language,
                "检查命令入口与输入依赖",
                "Check the command entry and input dependencies",
            )
            .to_owned(),
            resource_kind: None,
            resolver: Some(FacetResolver::Command {
                address: CHECK_ADDRESS.to_owned(),
                arguments: vec![command.address.clone(), "--json".to_owned()],
                accepts_tail: false,
                confirmation: None,
                returns: Some(COMMAND_CHECK_PROTOCOL.to_owned()),
            }),
            view: None,
        });
    }
    if !command.is_control()
        && !command.address.is_empty()
        && command.runnable
        && command.alias_of.is_none()
    {
        facets.push(operation_facet(
            "execute",
            FacetRenderer::Run,
            ">",
            text(language, "执行", "Run"),
            text(
                language,
                "设置参数并启动命令",
                "Set arguments and start the command",
            ),
            command_resolver(&command.address, [], true),
        ));
    }
    facets
}

fn operation_facet(
    id: &str,
    renderer: FacetRenderer,
    icon: &str,
    label: &str,
    summary: &str,
    resolver: FacetResolver,
) -> Facet {
    Facet {
        id: id.to_owned(),
        kind: FacetKind::Operation,
        renderer,
        icon: icon.to_owned(),
        label: label.to_owned(),
        summary: summary.to_owned(),
        resource_kind: None,
        resolver: Some(resolver),
        view: None,
    }
}

fn command_resolver<'a>(
    address: &str,
    arguments: impl IntoIterator<Item = &'a str>,
    accepts_tail: bool,
) -> FacetResolver {
    FacetResolver::Command {
        address: address.to_owned(),
        arguments: arguments.into_iter().map(str::to_owned).collect(),
        accepts_tail,
        confirmation: None,
        returns: None,
    }
}

fn text(language: EntryLanguage, zh_cn: &'static str, en: &'static str) -> &'static str {
    match language {
        EntryLanguage::ZhCn => zh_cn,
        EntryLanguage::En => en,
    }
}
