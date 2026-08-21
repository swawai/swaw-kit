use swawkit_proj_protocol::{CommandIdentity, CommandSpace, ResourceRoute};

#[cfg(test)]
use super::super::CommandNode;

const SYSTEM_FACET: &str = "system";
const MODULES_FACET: &str = "modules";
const SUBCOMMANDS_FACET: &str = "subcommands";

pub(in crate::catalog) fn resource_route_for_command(
    command: &CommandIdentity,
) -> Result<ResourceRoute, String> {
    swawkit_proj_protocol::command_resource_route(command).map_err(|error| error.to_string())
}

pub(in crate::catalog) fn command_identity_for_resource_route(
    route: &ResourceRoute,
) -> Result<CommandIdentity, String> {
    let mut hops = route.hops().iter();
    let first = hops
        .next()
        .ok_or("the root Resource is not a Command provider")?;
    let (space, namespace, mut path) = match first.facet() {
        SYSTEM_FACET => (
            CommandSpace::System,
            None,
            vec![first.selector().to_owned()],
        ),
        MODULES_FACET => {
            let command = hops
                .next()
                .ok_or("a Module namespace Resource is not a Command provider")?;
            if command.facet() != SUBCOMMANDS_FACET {
                return Err("a Module Command Resource must enter through subcommands".to_owned());
            }
            (
                CommandSpace::Module,
                Some(first.selector()),
                vec![command.selector().to_owned()],
            )
        }
        _ => return Err("a Command Resource must enter through system or modules".to_owned()),
    };
    for hop in hops {
        if hop.facet() != SUBCOMMANDS_FACET {
            return Err("a nested Command Resource must enter through subcommands".to_owned());
        }
        path.push(hop.selector().to_owned());
    }
    CommandIdentity::new(space, namespace, path).map_err(|error| error.to_string())
}

#[cfg(test)]
pub(super) fn resource_route_for_node(node: &CommandNode) -> Result<ResourceRoute, String> {
    if node.path.is_empty() {
        return match node.space {
            CommandSpace::System if node.address.is_empty() && node.namespace.is_none() => {
                Ok(ResourceRoute::root())
            }
            CommandSpace::Module
                if node.address == node.namespace.as_deref().unwrap_or_default() =>
            {
                ResourceRoute::root()
                    .child(
                        MODULES_FACET,
                        node.namespace
                            .as_deref()
                            .ok_or("Module Catalog root has no namespace")?,
                    )
                    .map_err(|error| error.to_string())
            }
            _ => Err(format!(
                "Catalog root '{}' has inconsistent identity fields",
                node.address
            )),
        };
    }

    let command = CommandIdentity::new(node.space, node.namespace.as_deref(), node.path.clone())
        .map_err(|error| error.to_string())?;
    if command.address() != node.address {
        return Err(format!(
            "Catalog command address '{}' disagrees with its structured identity '{}'",
            node.address,
            command.address()
        ));
    }
    resource_route_for_command(&command)
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use swawkit_proj_protocol::{CommandIdentity, ResourceRoute, command_data_root};

    use super::{
        command_identity_for_resource_route, resource_route_for_command, resource_route_for_node,
    };
    use crate::catalog::CatalogSnapshot;

    #[test]
    fn projects_current_command_identities_without_replacing_them() {
        for (address, route) in [
            (".dev", "$/system::dev"),
            (".dev/bun", "$/system::dev/subcommands::bun"),
            (
                ".dev/bun/mode",
                "$/system::dev/subcommands::bun/subcommands::mode",
            ),
            ("swaw/context", "$/modules::swaw/subcommands::context"),
            (
                "swaw/context/add",
                "$/modules::swaw/subcommands::context/subcommands::add",
            ),
        ] {
            let command = CommandIdentity::parse(address).unwrap();
            assert_eq!(
                resource_route_for_command(&command)
                    .unwrap()
                    .canonical_route(),
                route
            );
            assert_eq!(command.address(), address);
            assert_eq!(
                command_identity_for_resource_route(&resource_route_for_command(&command).unwrap())
                    .unwrap(),
                command
            );
        }
    }

    #[test]
    fn only_command_shaped_resource_routes_compile_to_backing_identities() {
        for invalid in [
            "$",
            "$/modules::swaw",
            "$/system::dev/tools::bun",
            "$/contexts::fixture",
        ] {
            let route = ResourceRoute::parse(invalid).unwrap();
            assert!(
                command_identity_for_resource_route(&route).is_err(),
                "{invalid}"
            );
        }
    }

    #[test]
    fn data_root_remains_keyed_by_the_backing_command_identity() {
        let command = CommandIdentity::parse(".dev/bun/mode").unwrap();
        let route = resource_route_for_command(&command).unwrap();
        assert_eq!(
            command_data_root(Path::new("entry-data"), &command),
            Path::new("entry-data/modules/system/dev/bun/mode")
        );
        assert_eq!(
            route.canonical_route(),
            "$/system::dev/subcommands::bun/subcommands::mode"
        );
    }

    #[test]
    fn projects_real_current_catalog_facts() {
        let project = Path::new(env!("CARGO_MANIFEST_DIR"));
        let system = project.join("../system");
        let absent = project.join("target/resource-loader-absent-modules");
        let catalog = CatalogSnapshot::discover_roots(&system, &absent, &absent, "fixture")
            .expect("discover current System Catalog");

        for (address, route, runnable) in [
            ("", "$", true),
            (".check", "$/system::check", true),
            (".check/dir", "$/system::check/subcommands::dir", false),
            (
                ".check/dir/exists",
                "$/system::check/subcommands::dir/subcommands::exists",
                true,
            ),
            (".entry", "$/system::entry", true),
            (".entry/apply", "$/system::entry/subcommands::apply", true),
            (
                ".entry/instances",
                "$/system::entry/subcommands::instances",
                true,
            ),
            (
                ".entry/instances/create",
                "$/system::entry/subcommands::instances/subcommands::create",
                true,
            ),
            (
                ".entry/instances/migrate",
                "$/system::entry/subcommands::instances/subcommands::migrate",
                true,
            ),
            (
                ".entry/language",
                "$/system::entry/subcommands::language",
                true,
            ),
            (
                ".entry/project",
                "$/system::entry/subcommands::project",
                false,
            ),
            (
                ".entry/project/root",
                "$/system::entry/subcommands::project/subcommands::root",
                true,
            ),
            (".runtime", "$/system::runtime", true),
            (
                ".runtime/cleanup",
                "$/system::runtime/subcommands::cleanup",
                true,
            ),
            (
                ".runtime/host",
                "$/system::runtime/subcommands::host",
                false,
            ),
            (
                ".runtime/host/exit",
                "$/system::runtime/subcommands::host/subcommands::exit",
                true,
            ),
            (
                ".runtime/host/restart",
                "$/system::runtime/subcommands::host/subcommands::restart",
                true,
            ),
            (".module", "$/system::module", false),
            (
                ".module/instantiate",
                "$/system::module/subcommands::instantiate",
                true,
            ),
            (
                ".module/status",
                "$/system::module/subcommands::status",
                true,
            ),
            (".dev", "$/system::dev", false),
            (".dev/bun", "$/system::dev/subcommands::bun", true),
            (
                ".dev/bun/mode",
                "$/system::dev/subcommands::bun/subcommands::mode",
                true,
            ),
            (".context", "$/system::context", true),
            (".context/add", "$/system::context/subcommands::add", true),
            (
                ".context/delete",
                "$/system::context/subcommands::delete",
                true,
            ),
            (".context/list", "$/system::context/subcommands::list", true),
            (".context/new", "$/system::context/subcommands::new", true),
            (".context/note", "$/system::context/subcommands::note", true),
            (
                ".context/prompt",
                "$/system::context/subcommands::prompt",
                true,
            ),
            (
                ".context/remove",
                "$/system::context/subcommands::remove",
                true,
            ),
            (
                ".context/render",
                "$/system::context/subcommands::render",
                true,
            ),
            (".context/show", "$/system::context/subcommands::show", true),
            (".runs", "$/system::runs", true),
            (".help", "$/system::help", true),
            (".view", "$/system::view", false),
            (".view/source", "$/system::view/subcommands::source", true),
        ] {
            let node = catalog
                .commands
                .iter()
                .find(|node| node.address == address)
                .unwrap_or_else(|| panic!("current Catalog is missing {address}"));
            assert_eq!(node.runnable, runnable, "{address}");
            assert_eq!(node.diagnostic, None, "{address}");
            assert_eq!(
                resource_route_for_node(node).unwrap().canonical_route(),
                route
            );
        }

        assert!(
            catalog
                .commands
                .iter()
                .all(|command| command.path.is_empty() || command.authored_resource),
            "the current System tree must not depend on Command Module authoring"
        );
        assert!(catalog.commands.iter().all(|command| {
            command
                .facets
                .iter()
                .all(|facet| !matches!(facet.id.as_str(), "children" | "run"))
        }));
        let dev = catalog
            .commands
            .iter()
            .find(|node| node.address == ".dev")
            .unwrap();
        assert!(dev.facets.iter().any(|facet| {
            facet.id == "subcommands"
                && matches!(
                    facet.resolver.as_ref(),
                    Some(crate::facet::FacetResolver::Catalog { relation })
                        if relation == "subcommands"
                )
        }));
        let bun = catalog
            .commands
            .iter()
            .find(|node| node.address == ".dev/bun")
            .unwrap();
        assert!(bun.facets.iter().any(|facet| facet.id == "execute"));
        let bun_runs = bun
            .facets
            .iter()
            .find(|facet| facet.id == "runs")
            .expect("explicit Bun runs Facet");
        assert_eq!(
            bun_runs.resource_kind.as_ref().unwrap().source.to_string(),
            "$/system::runs/all"
        );

        let context = catalog
            .commands
            .iter()
            .find(|node| node.address == ".context")
            .unwrap();
        assert_eq!(context.native_owner.as_deref(), Some(".context"));
        let contexts = context
            .facets
            .iter()
            .find(|facet| facet.id == "contexts")
            .unwrap();
        assert_eq!(
            contexts.view.as_ref().unwrap().column.width,
            swawkit_proj_protocol::WebColumnWidth::Wide
        );
        assert_eq!(context.resource_kinds[0].kind, "context");
        assert_eq!(context.resource_kinds[0].facets.len(), 7);
        for address in [
            ".context/add",
            ".context/delete",
            ".context/list",
            ".context/new",
            ".context/note",
            ".context/prompt",
            ".context/remove",
            ".context/render",
            ".context/show",
        ] {
            let command = catalog
                .commands
                .iter()
                .find(|node| node.address == address)
                .unwrap();
            assert_eq!(command.native_owner.as_deref(), Some(".context"));
        }

        let runs = catalog
            .commands
            .iter()
            .find(|node| node.address == ".runs")
            .unwrap();
        let all = runs.facets.iter().find(|facet| facet.id == "all").unwrap();
        assert_eq!(
            all.view.as_ref().unwrap().column.width,
            swawkit_proj_protocol::WebColumnWidth::Wide
        );
        assert_eq!(runs.resource_kinds[0].kind, "run");
        assert_eq!(runs.resource_kinds[0].facets.len(), 2);

        let help = catalog
            .commands
            .iter()
            .find(|node| node.address == ".help")
            .unwrap();
        assert!(help.authored_resource);
        assert_eq!(help.entry.as_deref(), Some("swawkit.execution.json"));
        assert_eq!(help.adapter.as_deref(), Some("core"));
        assert!(help.directory.ends_with("help"));
        assert!(help.executor_directory.ends_with("help/execute"));
        assert!(help.facets.iter().all(|facet| facet.id != "runs"));

        let view_source = catalog
            .commands
            .iter()
            .find(|node| node.address == ".view/source")
            .unwrap();
        assert_eq!(view_source.handler.as_deref(), Some("meta.view.source"));
        assert!(
            view_source
                .executor_directory
                .ends_with("view/subcommands/source/execute")
        );

        let check = catalog
            .commands
            .iter()
            .find(|node| node.address == ".check")
            .unwrap();
        assert!(check.authored_resource);
        assert_eq!(check.entry.as_deref(), Some("swawkit.execution.json"));
        assert_eq!(check.adapter.as_deref(), Some("core"));
        assert!(check.directory.ends_with("check"));
        assert!(check.executor_directory.ends_with("check/execute"));
        assert!(check.facets.iter().all(|facet| facet.id != "runs"));

        let directory_check = catalog
            .commands
            .iter()
            .find(|node| node.address == ".check/dir/exists")
            .unwrap();
        assert!(directory_check.authored_resource);
        assert_eq!(
            directory_check.handler.as_deref(),
            Some("meta.check.dir.exists")
        );
        assert!(
            directory_check
                .executor_directory
                .ends_with("check/subcommands/dir/subcommands/exists/execute")
        );

        for (address, handler, directory) in [
            (".entry", "entry.config", "entry/execute"),
            (
                ".entry/instances/create",
                "entry.instances.create",
                "entry/subcommands/instances/subcommands/create/execute",
            ),
            (
                ".entry/project/root",
                "entry.config.set",
                "entry/subcommands/project/subcommands/root/execute",
            ),
        ] {
            let node = catalog
                .commands
                .iter()
                .find(|node| node.address == address)
                .unwrap();
            assert!(node.authored_resource, "{address}");
            assert_eq!(node.handler.as_deref(), Some(handler), "{address}");
            assert!(node.help.is_some(), "{address}");
            assert!(node.executor_directory.ends_with(directory), "{address}");
        }

        for (address, handler) in [
            (".runtime", "runtime.status"),
            (".runtime/cleanup", "runtime.cleanup"),
            (".runtime/host/exit", "host.exit"),
            (".runtime/host/restart", "host.restart"),
        ] {
            let node = catalog
                .commands
                .iter()
                .find(|node| node.address == address)
                .unwrap();
            assert!(node.authored_resource, "{address}");
            assert_eq!(node.handler.as_deref(), Some(handler), "{address}");
            assert!(node.help.is_some(), "{address}");
        }

        for (address, directory) in [
            (".module/instantiate", "module/subcommands/instantiate"),
            (".module/status", "module/subcommands/status"),
        ] {
            let node = catalog
                .commands
                .iter()
                .find(|node| node.address == address)
                .unwrap();
            assert!(node.authored_resource, "{address}");
            assert_eq!(node.adapter.as_deref(), Some("runtime"), "{address}");
            assert_eq!(node.product.as_deref(), Some("module"), "{address}");
            assert!(node.directory.ends_with(directory), "{address}");
            assert!(node.executor_directory.ends_with("execute"), "{address}");
        }
    }
}
