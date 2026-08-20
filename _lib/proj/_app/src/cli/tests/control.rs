use super::*;

#[test]
fn runtime_status_is_available_without_entry_config() {
    let fixture = Fixture::with_entry_runtime();
    fixture.core_command(".runtime", "runtime.status");

    let exit_code = run(
        &fixture.context,
        &argv(&[".runtime", "--json"]),
        CommandProcessMode::InheritConsole,
    )
    .unwrap();

    assert_eq!(exit_code, 0);
    assert!(!fixture.data_root().join("_entry-config.json").exists());
}

#[test]
fn runtime_controls_require_a_ready_owned_data_root() {
    let fixture = Fixture::new();
    fixture.core_command(".runtime", "runtime.status");

    let error = run(
        &fixture.context,
        &argv(&[".runtime", "--json"]),
        CommandProcessMode::InheritConsole,
    )
    .expect_err("Runtime control must not bypass Entry identity");

    assert!(error.to_string().contains("DataRoot resolution failed"));
    assert!(!fixture.data_root().exists());
}

#[test]
fn runtime_controls_ignore_unrelated_files_in_the_data_root() {
    let fixture = Fixture::with_entry_runtime();
    fixture.core_command(".runtime", "runtime.status");
    fs::write(
        fixture.data_root().join("user-created.txt"),
        b"not framework identity",
    )
    .expect("replace fixture Entry ID before it is pinned");

    let exit_code = run(
        &fixture.context,
        &argv(&[".runtime", "--json"]),
        CommandProcessMode::InheritConsole,
    )
    .expect("unrelated DataRoot files must not affect Runtime identity");
    assert_eq!(exit_code, 0);
}

#[test]
fn entry_config_settings_are_independent_typed_catalog_commands() {
    let fixture = Fixture::new();
    for address in EntryConfigRecord::setting_addresses() {
        fixture.core_command(address, "entry.config.set");
    }

    let snapshot = CatalogSnapshot::discover(&fixture.context, None).unwrap();
    let setters = snapshot
        .commands
        .iter()
        .filter(|command| command.handler.as_deref() == Some("entry.config.set"))
        .collect::<Vec<_>>();

    assert_eq!(setters.len(), 2);
    assert!(setters.iter().all(|command| {
        let expected_parent = command.address.rsplit_once('/').map(|(parent, _)| parent);
        command.parent.as_deref() == expected_parent
            && EntryConfigRecord::is_setting_address(&command.address)
    }));
}

#[test]
fn entry_control_commands_create_and_update_entry_config() {
    let fixture = Fixture::new();
    fixture.core_command(".entry", "entry.config");
    fixture.core_command(".entry/language", "entry.config.set");
    fixture.core_command(".entry/apply", "entry.config.apply");
    fixture.command(
        ".entry/project",
        "swawkit.module.json",
        r#"{"schema":"swawkit.command-module/v11"}"#,
    );
    fs::create_dir_all(fixture.context.system_root().join("entry/project/_help")).unwrap();
    fs::write(
        fixture
            .context
            .system_root()
            .join("entry/project/_help/zh-CN.txt"),
        "Set Entry Config project settings",
    )
    .unwrap();
    fixture.initialize();

    assert_eq!(
        run(
            &fixture.context,
            &argv(&[".entry", "--json"]),
            CommandProcessMode::InheritConsole,
        )
        .unwrap(),
        0
    );
    assert!(!fixture.data_root().join("_entry-config.json").exists());

    assert_eq!(
        run(
            &fixture.context,
            &argv(&[".entry/project", "--help"]),
            CommandProcessMode::InheritConsole,
        )
        .unwrap(),
        0
    );
    assert!(!fixture.data_root().join("_entry-config.json").exists());

    assert_eq!(
        run(
            &fixture.context,
            &argv(&[".entry/language", "en"]),
            CommandProcessMode::InheritConsole,
        )
        .unwrap(),
        0
    );
    let EntryConfigState::Ready(config) =
        EntryConfigStore::new(&fixture.context.swawkit_home, fixture.data_root()).read()
    else {
        panic!("expected ready Entry Config");
    };
    assert_eq!(config.record().language, "en");

    let before_invalid_update = fs::read(fixture.data_root().join("_entry-config.json")).unwrap();
    let invalid_update = run(
        &fixture.context,
        &argv(&[".entry/unknown", "value"]),
        CommandProcessMode::InheritConsole,
    )
    .unwrap_err();
    assert!(invalid_update.to_string().contains("command not found"));
    assert_eq!(
        fs::read(fixture.data_root().join("_entry-config.json")).unwrap(),
        before_invalid_update
    );

    let mut replacement = config.record().clone();
    replacement.language = "zh-CN".to_owned();
    let input = fixture.project_root.join("entry-config.json");
    fs::write(&input, serde_json::to_string(&replacement).unwrap()).unwrap();
    assert_eq!(
        run(
            &fixture.context,
            &argv(&[".entry/apply", "--file", "entry-config.json"]),
            CommandProcessMode::InheritConsole,
        )
        .unwrap(),
        0
    );
    let EntryConfigState::Ready(config) =
        EntryConfigStore::new(&fixture.context.swawkit_home, fixture.data_root()).read()
    else {
        panic!("expected applied Entry Config");
    };
    assert_eq!(config.record().language, "zh-CN");
}

#[test]
fn oversized_entry_config_does_not_block_system_or_swaw_and_apply_is_recoverable() {
    let fixture = Fixture::new();
    fixture.core_command(".entry/apply", "entry.config.apply");
    fixture.command(".system-ok", "run.cmd", "@exit /b 17\r\n");
    let swaw = fixture.context.swaw_module_root().join("swaw-ok");
    fs::create_dir_all(&swaw).unwrap();
    fs::write(
        swaw.join("swawkit.module.json"),
        r#"{"schema":"swawkit.command-module/v11"}"#,
    )
    .unwrap();
    fs::write(swaw.join("run.cmd"), "@exit /b 18\r\n").unwrap();
    fixture.initialize();

    let stored_path = fixture.data_root().join("_entry-config.json");
    let oversized = vec![b'x'; ENTRY_CONFIG_MAX_BYTES as usize + 1];
    fs::write(&stored_path, &oversized).unwrap();
    assert!(matches!(
        EntryConfigStore::new(&fixture.context.swawkit_home, fixture.data_root()).read(),
        EntryConfigState::Invalid { .. }
    ));

    assert_eq!(
        run(
            &fixture.context,
            &argv(&[".system-ok"]),
            CommandProcessMode::InheritConsole,
        )
        .unwrap(),
        17
    );
    assert_eq!(
        run(
            &fixture.context,
            &argv(&["swaw/swaw-ok"]),
            CommandProcessMode::InheritConsole,
        )
        .unwrap(),
        18
    );

    let input = fixture.project_root.join("entry-config.json");
    fs::write(&input, &oversized).unwrap();
    let before_apply = fs::read(&stored_path).unwrap();
    let error = run(
        &fixture.context,
        &argv(&[".entry/apply", "--file", "entry-config.json"]),
        CommandProcessMode::InheritConsole,
    )
    .expect_err("an oversized apply input must be rejected");
    assert!(error.to_string().contains("no larger than 65536 bytes"));
    assert_eq!(fs::read(&stored_path).unwrap(), before_apply);

    fs::write(
        &input,
        serde_json::to_vec(&EntryConfigRecord::default()).unwrap(),
    )
    .unwrap();
    assert_eq!(
        run(
            &fixture.context,
            &argv(&[".entry/apply", "--file", "entry-config.json"]),
            CommandProcessMode::InheritConsole,
        )
        .unwrap(),
        0
    );
    assert!(matches!(
        EntryConfigStore::new(&fixture.context.swawkit_home, fixture.data_root()).read(),
        EntryConfigState::Ready(_)
    ));
}
