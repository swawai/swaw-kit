use super::*;

fn delegate_manifest(owner: &str) -> String {
    format!(
        r#"{{"schema":"swawkit.command-module/v12","execution":{{"type":"delegate","owner":{{"type":"command","space":"module","namespace":"swaw","address":"{owner}"}}}}}}"#
    )
}

fn native_manifest() -> &'static str {
    r#"{"schema":"swawkit.command-module/v12","execution":{"type":"native"}}"#
}

fn system_delegate_manifest(owner: &str) -> String {
    format!(
        r#"{{"schema":"swawkit.command-module/v12","execution":{{"type":"delegate","owner":{{"type":"command","space":"system","address":"{owner}"}}}}}}"#
    )
}

#[test]
fn native_adapter_runs_only_the_selected_content_addressed_export() {
    let fixture = Fixture::new();
    let directory = module_directory(&fixture.swaw_module_root, "native-export");
    fs::create_dir_all(&directory).unwrap();
    fs::write(directory.join("swawkit.module.json"), native_manifest()).unwrap();

    let executable =
        PathBuf::from(env::var_os("SystemRoot").expect("SystemRoot")).join("System32/whoami.exe");
    let bytes = fs::read(executable).unwrap();
    let module_data_root = fixture.data_root.join("modules/swaw/native-export");
    fs::create_dir_all(&module_data_root).unwrap();
    let catalog = fixture.catalog();
    let owner = catalog
        .commands
        .iter()
        .find(|command| command.address == "swaw/native-export")
        .unwrap();
    crate::native_command::publish_test_executable(&module_data_root, &catalog, owner, &bytes)
        .unwrap();
    let exit_code = CommandExecutor::new(&fixture.context(), &catalog)
        .execute(&argv(&["swaw/native-export"]))
        .unwrap();

    assert_eq!(exit_code, 0);
}

#[test]
fn delegated_port_runs_the_selected_owner_executable() {
    let fixture = Fixture::new();
    let owner = module_directory(&fixture.swaw_module_root, "domain");
    let port = module_directory(&fixture.swaw_module_root, "domain/port");
    fs::create_dir_all(&port).unwrap();
    fs::write(owner.join("swawkit.module.json"), native_manifest()).unwrap();
    fs::write(
        port.join("swawkit.module.json"),
        delegate_manifest("swaw/domain"),
    )
    .unwrap();

    let executable =
        PathBuf::from(env::var_os("SystemRoot").expect("SystemRoot")).join("System32/whoami.exe");
    let bytes = fs::read(executable).unwrap();
    let module_data_root = fixture.data_root.join("modules/swaw/domain");
    fs::create_dir_all(&module_data_root).unwrap();
    let catalog = fixture.catalog();
    let owner = catalog
        .commands
        .iter()
        .find(|command| command.address == "swaw/domain")
        .unwrap();
    crate::native_command::publish_test_executable(&module_data_root, &catalog, owner, &bytes)
        .unwrap();
    let exit_code = CommandExecutor::new(&fixture.context(), &catalog)
        .execute(&argv(&["swaw/domain/port"]))
        .unwrap();

    assert_eq!(exit_code, 0);
}

#[test]
fn system_delegated_port_runs_its_selected_system_owner_export() {
    let fixture = Fixture::new();
    let owner = command_directory(&fixture.system_root, ".context");
    let port = command_directory(&fixture.system_root, ".context/add");
    fs::create_dir_all(&port).unwrap();
    fs::write(owner.join("swawkit.module.json"), native_manifest()).unwrap();
    fs::write(
        port.join("swawkit.module.json"),
        system_delegate_manifest(".context"),
    )
    .unwrap();

    let executable =
        PathBuf::from(env::var_os("SystemRoot").expect("SystemRoot")).join("System32/whoami.exe");
    let bytes = fs::read(executable).unwrap();
    let owner_data_root = fixture.data_root.join("modules/system/context");
    fs::create_dir_all(&owner_data_root).unwrap();
    let catalog = fixture.catalog();
    let owner = catalog
        .commands
        .iter()
        .find(|command| command.address == ".context")
        .unwrap();
    crate::native_command::publish_test_executable(&owner_data_root, &catalog, owner, &bytes)
        .unwrap();
    let exit_code = CommandExecutor::new(&fixture.context(), &catalog)
        .execute(&argv(&[".context/add"]))
        .unwrap();

    assert_eq!(exit_code, 0);
}

#[test]
fn native_adapter_does_not_build_an_uninstantiated_module_during_execution() {
    let fixture = Fixture::new();
    let directory = module_directory(&fixture.swaw_module_root, "native-missing");
    fs::create_dir_all(&directory).unwrap();
    fs::write(directory.join("swawkit.module.json"), native_manifest()).unwrap();
    let catalog = fixture.catalog();

    let error = CommandExecutor::new(&fixture.context(), &catalog)
        .execute(&argv(&["swaw/native-missing"]))
        .unwrap_err()
        .to_string();

    assert!(error.contains("has not been instantiated"), "{error}");
    assert!(
        error.contains("fixture .module/instantiate swaw/native-missing"),
        "{error}"
    );
    assert!(
        !fixture
            .data_root
            .join("modules/swaw/native-missing/_native")
            .exists()
    );
}

#[test]
fn journal_starts_before_native_artifact_preparation_fails() {
    let fixture = Fixture::new();
    let directory = module_directory(&fixture.swaw_module_root, "journaled-native-missing");
    fs::create_dir_all(&directory).unwrap();
    fs::write(directory.join("swawkit.module.json"), native_manifest()).unwrap();
    let catalog = fixture.catalog();

    let error = CommandExecutor::new(&fixture.context(), &catalog)
        .execute_journaled(&argv(&["swaw/journaled-native-missing"]))
        .expect_err("uninstantiated native command must fail");

    assert!(error.to_string().contains("has not been instantiated"));
    let runs_root = fixture
        .data_root
        .join("modules/swaw/journaled-native-missing/_runs");
    let run_root = fs::read_dir(runs_root)
        .unwrap()
        .next()
        .expect("failed preparation journal")
        .unwrap()
        .path();
    let state: serde_json::Value =
        serde_json::from_slice(&fs::read(run_root.join("_state.json")).unwrap()).unwrap();
    assert_eq!(state["status"], "failed");
    assert!(
        state["error"]
            .as_str()
            .is_some_and(|error| error.contains("has not been instantiated"))
    );
}

#[test]
fn delegated_native_port_points_instantiation_at_its_owner() {
    let fixture = Fixture::new();
    let owner = module_directory(&fixture.swaw_module_root, "context");
    let directory = module_directory(&fixture.swaw_module_root, "context/add");
    fs::create_dir_all(&directory).unwrap();
    fs::write(owner.join("swawkit.module.json"), native_manifest()).unwrap();
    fs::write(
        directory.join("swawkit.module.json"),
        delegate_manifest("swaw/context"),
    )
    .unwrap();
    let catalog = fixture.catalog();

    let error = CommandExecutor::new(&fixture.context(), &catalog)
        .execute(&argv(&["swaw/context/add"]))
        .unwrap_err()
        .to_string();

    assert!(error.contains("has not been instantiated"), "{error}");
    assert!(
        error.contains("fixture .module/instantiate swaw/context"),
        "{error}"
    );
    assert!(!error.contains("swaw/context/add'"), "{error}");
}
