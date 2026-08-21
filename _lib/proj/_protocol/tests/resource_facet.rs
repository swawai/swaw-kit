use std::{
    fs,
    path::{Path, PathBuf},
};

use swawkit_proj_protocol::{
    FacetExecution, FacetRoute, ResourceFacetKind, ResourceIdentity, ResourceKindManifest,
    ResourceList, ResourceListing, ResourceRoute, parse_facet_execution_manifest,
    parse_facet_requirements_manifest, parse_resource_exports_manifest,
    parse_resource_facet_manifest, parse_resource_kind_manifest, parse_resource_manifest,
    parse_web_view_source, resolve_web_view,
};

const FIXTURE_ROOT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/resource-facet");

#[derive(Debug, Default, PartialEq, Eq)]
struct TreeFacts {
    resources: usize,
    facets: usize,
    kinds: usize,
    executions: usize,
    requirements: usize,
    exports: usize,
    local_entries: usize,
    views: usize,
}

#[test]
fn flat_static_tree_matches_the_real_dev_execution_boundary() {
    let root = Path::new(FIXTURE_ROOT).join("static/dev");
    let reference = ResourceRoute::parse("$/system::dev").unwrap();
    let facts = inspect_resource(&root, &reference);

    assert_eq!(
        facts,
        TreeFacts {
            resources: 4,
            facets: 5,
            executions: 2,
            requirements: 1,
            exports: 1,
            local_entries: 1,
            views: 1,
            ..TreeFacts::default()
        }
    );
    assert!(FacetRoute::parse("$/system::dev/execute").is_ok());
    assert!(!root.join("execute/swawkit.facet.json").exists());

    let bun_execute = root.join("subcommands/bun/execute");
    assert!(bun_execute.join("swawkit.facet.json").is_file());
    assert!(bun_execute.join("run.ps1").is_file());

    let actual =
        FacetRoute::parse("$/system::dev/subcommands::bun/subcommands::mode/execute").unwrap();
    assert!(
        root.join("subcommands/bun/subcommands/mode/execute/swawkit.execution.json")
            .is_file()
    );
    assert_eq!(actual.facet(), "execute");
}

#[test]
fn dynamic_kind_reuses_invoke_templates_without_a_runtime_directory_protocol() {
    let source = Path::new(FIXTURE_ROOT).join("dynamic/context");
    let owner = ResourceRoute::parse("$/system::context").unwrap();
    let facts = inspect_resource(&source, &owner);
    assert_eq!(
        facts,
        TreeFacts {
            resources: 1,
            facets: 3,
            kinds: 1,
            executions: 3,
            views: 1,
            ..TreeFacts::default()
        }
    );

    let kind =
        parse_resource_kind_manifest(&read(&source.join("contexts/swawkit.resource-kind.json")))
            .unwrap();
    let ResourceKindManifest::Definition(kind) = kind else {
        panic!("fixture must define its Resource Kind locally");
    };
    assert_eq!(kind.kind, "context");

    let instance_route = ResourceRoute::parse("$/system::context/contexts::release-check").unwrap();
    let overview = FacetRoute::new(instance_route, "overview").unwrap();
    assert_eq!(
        overview.canonical_route(),
        "$/system::context/contexts::release-check/overview"
    );
}

#[test]
fn facet_view_resolves_the_same_snapshot_as_the_resource_list() {
    let target = FacetRoute::parse("$/system::dev/subcommands").unwrap();
    let bun = ResourceRoute::parse("$/system::dev/subcommands::bun").unwrap();
    let list = ResourceList::new(
        target.clone(),
        vec![
            ResourceListing::new(
                ResourceIdentity::static_resource(bun.clone()).unwrap(),
                "bun",
                bun,
                vec!["subcommands".to_owned()],
                "Bun",
                "Development tools",
            )
            .unwrap(),
        ],
    )
    .unwrap();
    let view_path = Path::new(FIXTURE_ROOT).join("static/dev/subcommands/view/web.json");
    let source = parse_web_view_source(&read(&view_path)).unwrap();
    let bundle = resolve_web_view(source, target.clone(), list).unwrap();

    assert_eq!(bundle.target(), &target);
    assert_eq!(bundle.resources()["facet-result"].resources().len(), 1);
}

fn inspect_resource(directory: &Path, reference: &ResourceRoute) -> TreeFacts {
    parse_resource_manifest(&read(&directory.join("swawkit.resource.json")))
        .expect("valid Resource marker");
    let mut facts = TreeFacts {
        resources: 1,
        ..TreeFacts::default()
    };
    let exports = directory.join("swawkit.exports.json");
    if exports.is_file() {
        parse_resource_exports_manifest(&read(&exports)).expect("valid Resource Exports");
        facts.exports += 1;
    }
    for child in child_directories(directory) {
        let facet_file = child.join("swawkit.facet.json");
        assert!(
            facet_file.is_file(),
            "Resource child must be a marked Facet: {}",
            child.display()
        );
        let name = file_name(&child);
        let facet = FacetRoute::new(reference.clone(), &name).expect("canonical Facet directory");
        add(&mut facts, inspect_facet(&child, &facet));
    }
    facts
}

fn inspect_facet(directory: &Path, reference: &FacetRoute) -> TreeFacts {
    let manifest = parse_resource_facet_manifest(&read(&directory.join("swawkit.facet.json")))
        .expect("valid Facet marker");
    let mut facts = TreeFacts {
        facets: 1,
        ..TreeFacts::default()
    };

    let execution = directory.join("swawkit.execution.json");
    if execution.is_file() {
        let execution =
            parse_facet_execution_manifest(&read(&execution)).expect("valid Facet execution");
        if reference.facet() == "execute" {
            assert_eq!(manifest.kind, ResourceFacetKind::Operation);
            assert!(!matches!(
                execution.implementation,
                FacetExecution::Invoke { .. }
            ));
        } else {
            assert!(matches!(
                execution.implementation,
                FacetExecution::Invoke { .. }
            ));
        }
        facts.executions += 1;
    }
    let requirements = directory.join("swawkit.requirements.json");
    if requirements.is_file() {
        assert_eq!(reference.facet(), "execute");
        parse_facet_requirements_manifest(&read(&requirements)).expect("valid Facet Requirements");
        facts.requirements += 1;
    }
    let local_entries = ["run.exe", "run.ts", "run.py", "run.ps1", "run.cmd"]
        .into_iter()
        .filter(|name| directory.join(name).is_file())
        .count();
    assert!(local_entries <= 1, "only one local Facet entry is allowed");
    if local_entries == 1 {
        assert_eq!(reference.facet(), "execute");
        assert!(
            !execution.is_file(),
            "local and declared execution conflict"
        );
        facts.local_entries += 1;
    }

    let kind_path = directory.join("swawkit.resource-kind.json");
    let has_kind = kind_path.is_file();
    if has_kind {
        assert_eq!(manifest.kind, ResourceFacetKind::Collection);
        parse_resource_kind_manifest(&read(&kind_path)).expect("valid Resource Kind");
        facts.kinds += 1;
    }

    for child in child_directories(directory) {
        let name = file_name(&child);
        if name == "view" {
            parse_web_view_source(&read(&child.join("web.json"))).expect("valid Web View Source");
            facts.views += 1;
            continue;
        }
        if child.join("swawkit.resource.json").is_file() {
            assert_eq!(manifest.kind, ResourceFacetKind::Collection);
            assert_eq!(reference.facet(), "subcommands");
            let child_ref = reference
                .resource()
                .child(reference.facet(), &name)
                .expect("canonical static Resource directory");
            add(&mut facts, inspect_resource(&child, &child_ref));
            continue;
        }
        if has_kind && child.join("swawkit.facet.json").is_file() {
            let instance = reference
                .resource()
                .child(reference.facet(), "fixture-instance")
                .unwrap();
            let template_route =
                FacetRoute::new(instance, &name).expect("canonical template Facet");
            add(&mut facts, inspect_facet(&child, &template_route));
            continue;
        }
        panic!("unmarked Facet child: {}", child.display());
    }
    facts
}

fn child_directories(directory: &Path) -> Vec<PathBuf> {
    let mut children = fs::read_dir(directory)
        .unwrap_or_else(|error| panic!("cannot inspect '{}': {error}", directory.display()))
        .filter_map(|entry| {
            let entry = entry.expect("fixture directory entry");
            entry
                .file_type()
                .expect("fixture file type")
                .is_dir()
                .then(|| entry.path())
        })
        .collect::<Vec<_>>();
    children.sort();
    children
}

fn file_name(path: &Path) -> String {
    path.file_name()
        .and_then(|name| name.to_str())
        .expect("UTF-8 fixture directory")
        .to_owned()
}

fn read(path: &Path) -> Vec<u8> {
    fs::read(path).unwrap_or_else(|error| panic!("cannot read '{}': {error}", path.display()))
}

fn add(target: &mut TreeFacts, source: TreeFacts) {
    target.resources += source.resources;
    target.facets += source.facets;
    target.kinds += source.kinds;
    target.executions += source.executions;
    target.requirements += source.requirements;
    target.exports += source.exports;
    target.local_entries += source.local_entries;
    target.views += source.views;
}
