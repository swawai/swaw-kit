use super::*;

const INSTANCES: &str = ".entry/instances";
const CREATE: &str = ".entry/instances/create";
const MIGRATE: &str = ".entry/instances/migrate";

fn manager_fixture() -> Fixture {
    let mut fixture = Fixture::new();
    fs::remove_file(&fixture.context.entry_file).expect("remove generic Entry fixture");
    fixture.context.entry_file = fixture.root.join("swawkit.exe");
    fs::write(&fixture.context.entry_file, b"manager-launcher")
        .expect("write manager Launcher fixture");
    fixture.context.entry_name = "swawkit".to_owned();
    fixture.context.data_root = fixture.root.join("data/proj.swawkit");
    fixture.initialize();

    let runtime_root = fixture.data_root().join("runtime");
    let release_id = write_runtime_fixture(&fixture.root, &runtime_root);
    fs::write(runtime_root.join("current"), format!("{release_id}\n"))
        .expect("write manager Runtime selector fixture");
    fixture.context.runtime_root = runtime_root.clone();
    fixture.context.product_executable = runtime_root
        .join("releases")
        .join(&release_id)
        .join("swawkit-proj.exe");
    fixture.context.release_id = release_id;
    fixture
}

fn install_entry_manager_commands(fixture: &Fixture) {
    fixture.core_command(INSTANCES, "entry.instances");
    fixture.core_command(CREATE, "entry.instances.create");
    fixture.core_command(MIGRATE, "entry.instances.migrate");
}

#[test]
fn manager_inventory_runs_before_profile_gating() {
    let fixture = manager_fixture();
    install_entry_manager_commands(&fixture);

    let exit_code = run(
        &fixture.context,
        &argv(&[INSTANCES, "--json"]),
        CommandProcessMode::InheritConsole,
    )
    .expect("list Entry instances without a profile");

    assert_eq!(exit_code, 0);
    assert!(!fixture.data_root().join("_profile.json").exists());
}

#[test]
fn ordinary_entries_cannot_use_manager_commands() {
    let fixture = Fixture::with_entry_runtime();
    install_entry_manager_commands(&fixture);

    let error = run(
        &fixture.context,
        &argv(&[INSTANCES]),
        CommandProcessMode::InheritConsole,
    )
    .expect_err("ordinary Entry must not receive manager authority");

    assert!(error.to_string().contains("manager"));
    assert!(!fixture.data_root().join("_profile.json").exists());
}

#[test]
fn invalid_create_arguments_fail_before_writing_a_target() {
    let fixture = manager_fixture();
    install_entry_manager_commands(&fixture);

    for invalid in [
        argv(&[CREATE]),
        argv(&[CREATE, "proj-one", "--unknown"]),
        argv(&[CREATE, "--json", "proj-one"]),
    ] {
        let error = run(
            &fixture.context,
            &invalid,
            CommandProcessMode::InheritConsole,
        )
        .expect_err("invalid mutation arguments must fail");
        assert!(error.to_string().contains("usage:"));
    }

    assert!(!fixture.root.join("proj-one.exe").exists());
    assert!(!fixture.root.join("data/proj.proj-one").exists());
}

#[test]
fn create_is_idempotent_and_does_not_create_a_profile() {
    let fixture = manager_fixture();
    install_entry_manager_commands(&fixture);
    let command = argv(&[CREATE, "proj-one", "--json"]);

    let data_root = fixture.root.join("data/proj.proj-one");
    assert_eq!(
        run(
            &fixture.context,
            &command,
            CommandProcessMode::InheritConsole,
        )
        .expect("create Entry instance"),
        0
    );
    let entry_id = fs::read(data_root.join("entry.id")).unwrap();
    assert_eq!(
        run(
            &fixture.context,
            &command,
            CommandProcessMode::InheritConsole,
        )
        .expect("retry Entry creation"),
        0
    );

    assert_eq!(
        fs::read(fixture.root.join("proj-one.exe")).unwrap(),
        fs::read(&fixture.context.entry_file).unwrap()
    );
    assert_eq!(fs::read(data_root.join("entry.id")).unwrap(), entry_id);
    assert!(data_root.join("runtime/current").is_file());
    assert!(!data_root.join("_profile.json").exists());
}

#[test]
fn legacy_data_root_changes_only_through_explicit_migrate() {
    let fixture = manager_fixture();
    install_entry_manager_commands(&fixture);
    let data_root = fixture.root.join("data/proj.legacy-one");
    fs::create_dir_all(&data_root).unwrap();
    fs::write(
        data_root.join("_entry.json"),
        serde_json::to_vec(&serde_json::json!({
            "schema": "swawkit.proj-entry.v0",
            "entryName": "legacy-one",
            "entryFile": "legacy-one.exe",
            "volumeId": r"\\?\Volume{01234567-89ab-cdef-0123-456789abcdef}",
            "fileId": "0123456789abcdef"
        }))
        .unwrap(),
    )
    .unwrap();

    let create_error = run(
        &fixture.context,
        &argv(&[CREATE, "legacy-one"]),
        CommandProcessMode::InheritConsole,
    )
    .expect_err("create must not implicitly migrate legacy state");
    assert!(create_error.to_string().contains("cannot be created"));
    assert!(!data_root.join("entry.id").exists());

    assert_eq!(
        run(
            &fixture.context,
            &argv(&[MIGRATE, "legacy-one", "--json"]),
            CommandProcessMode::InheritConsole,
        )
        .expect("explicitly migrate legacy Entry"),
        0
    );
    assert!(data_root.join("entry.id").is_file());
    assert!(fixture.root.join("legacy-one.exe").is_file());
    assert!(!data_root.join("_profile.json").exists());
}
