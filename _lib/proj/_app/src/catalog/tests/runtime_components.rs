use super::*;

const DEV_RUNTIME_ADDRESSES: [&str; 14] = [
    ".dev/settings",
    ".dev/setup",
    ".dev/setup/check",
    ".dev/status",
    ".dev/bun/mode",
    ".dev/bun/sha256",
    ".dev/bun/version",
    ".dev/pwsh/mode",
    ".dev/pwsh/sha256",
    ".dev/pwsh/version",
    ".dev/msvc/mode",
    ".dev/msvc/channel",
    ".dev/rust/mode",
    ".dev/rust/toolchain",
];

#[test]
fn runtime_components_are_exact_and_have_no_handler() {
    let fixture = Fixture::new();
    fixture.file(
        &fixture.system,
        "module/swawkit.module.json",
        module_manifest(),
    );
    fixture.file(
        &fixture.system,
        "module/instantiate/swawkit.module.json",
        r#"{"schema":"swawkit.command-module/v12","execution":{"type":"runtime","product":"module"}}"#,
    );
    fixture.file(
        &fixture.system,
        "module/status/swawkit.module.json",
        &runtime_manifest("module"),
    );
    fixture.file(
        &fixture.system,
        "dev/swawkit.module.json",
        module_manifest(),
    );
    for namespace in ["bun", "pwsh", "msvc", "rust"] {
        fixture.file(
            &fixture.system,
            &format!("dev/{namespace}/swawkit.module.json"),
            module_manifest(),
        );
    }
    for address in DEV_RUNTIME_ADDRESSES {
        fixture.file(
            &fixture.system,
            &format!("{}/swawkit.module.json", address.trim_start_matches('.')),
            &runtime_manifest("dev"),
        );
    }
    fixture.file(
        &fixture.system,
        "wrong-runtime/swawkit.module.json",
        &runtime_manifest("module"),
    );
    fixture.file(
        &fixture.swaw,
        "wrong-runtime/swawkit.module.json",
        &runtime_manifest("module"),
    );
    fixture.file(
        &fixture.system,
        "module/wrong-product/swawkit.module.json",
        &runtime_manifest("toolchain"),
    );

    let snapshot = fixture.discover();
    for (address, product) in [
        (".module/instantiate", "module"),
        (".module/status", "module"),
    ] {
        assert_runtime_component(&snapshot, address, product);
    }
    for address in DEV_RUNTIME_ADDRESSES {
        assert_runtime_component(&snapshot, address, "dev");
    }
    for address in [".module/instantiate", ".module/status"] {
        assert!(
            node(&snapshot, address)
                .module
                .as_ref()
                .expect("module manager contract")
                .requires
                .is_empty()
        );
    }
    for address in [
        ".wrong-runtime",
        "swaw/wrong-runtime",
        ".module/wrong-product",
    ] {
        let command = node(&snapshot, address);
        assert!(!command.runnable, "{address}");
        assert!(
            command
                .diagnostic
                .as_deref()
                .is_some_and(|message| message.contains("Runtime Component")),
            "{address}: {:?}",
            command.diagnostic
        );
    }
}

fn assert_runtime_component(snapshot: &CatalogSnapshot, address: &str, product: &str) {
    let command = node(snapshot, address);
    assert!(command.runnable, "{address}: {:?}", command.diagnostic);
    assert_eq!(command.adapter.as_deref(), Some("runtime"));
    assert_eq!(command.product.as_deref(), Some(product));
    assert_eq!(command.handler, None);
}

#[test]
fn unsafe_project_module_root_is_omitted_without_hiding_system_or_swaw() {
    let fixture = Fixture::new();
    fixture.file(
        &fixture.system,
        "kept/swawkit.module.json",
        module_manifest(),
    );
    fixture.file(&fixture.system, "kept/run.ps1", "exit 0");
    fixture.file(&fixture.swaw, "kept/swawkit.module.json", module_manifest());
    fixture.file(&fixture.swaw, "kept/run.ps1", "exit 0");
    let external = fixture.root.join("external-project-modules");
    fixture.file(&external, "hidden/swawkit.module.json", module_manifest());
    fixture.file(&external, "hidden/run.ps1", "exit 0");
    fs::remove_dir_all(&fixture.project).expect("remove regular project Module root");
    if std::os::windows::fs::symlink_dir(&external, &fixture.project).is_err() {
        return;
    }

    let snapshot = fixture.discover();
    let addresses = snapshot
        .commands
        .iter()
        .map(|command| command.address.as_str())
        .collect::<Vec<_>>();
    assert!(addresses.contains(&".kept"));
    assert!(addresses.contains(&"swaw/kept"));
    assert!(
        !addresses
            .iter()
            .any(|address| address.starts_with("project"))
    );

    fs::remove_dir(&fixture.project).expect("remove project Module root reparse point");
}
