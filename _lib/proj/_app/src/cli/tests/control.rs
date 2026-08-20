use super::*;

#[test]
fn runtime_status_is_available_before_profile_gating() {
    let fixture = Fixture::with_entry_runtime();
    fixture.core_command(".runtime", "runtime.status");

    let exit_code = run(
        &fixture.context,
        &argv(&[".runtime", "--json"]),
        CommandProcessMode::InheritConsole,
    )
    .unwrap();

    assert_eq!(exit_code, 0);
    assert!(!fixture.data_root().join("_profile.json").exists());
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
fn profile_settings_are_independent_typed_catalog_commands() {
    let fixture = Fixture::new();
    for address in EntryProfileRecord::profile_setting_addresses() {
        fixture.core_command(address, "entry.profile.set");
    }

    let snapshot = CatalogSnapshot::discover(&fixture.context, None).unwrap();
    let setters = snapshot
        .commands
        .iter()
        .filter(|command| command.handler.as_deref() == Some("entry.profile.set"))
        .collect::<Vec<_>>();

    assert_eq!(setters.len(), 18);
    assert!(setters.iter().all(|command| {
        let expected_parent = command.address.rsplit_once('/').map(|(parent, _)| parent);
        command.parent.as_deref() == expected_parent
            && EntryProfileRecord::is_profile_setting_address(&command.address)
    }));
}

#[test]
fn entry_control_commands_create_and_update_a_profile_before_profile_gating() {
    let fixture = Fixture::new();
    fixture.core_command(".entry", "entry.profile");
    fixture.core_command(".entry/git/name", "entry.profile.set");
    fixture.core_command(".dev/bun/mode", "entry.profile.set");
    fixture.core_command(".entry/apply", "entry.profile.apply");
    fs::create_dir_all(fixture.context.system_root().join("entry/git/_help")).unwrap();
    fs::write(
        fixture
            .context
            .system_root()
            .join("entry/git/_help/zh-CN.txt"),
        "Set Entry Profile Git settings",
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
    assert!(!fixture.data_root().join("_profile.json").exists());

    assert_eq!(
        run(
            &fixture.context,
            &argv(&[".entry/git", "--help"]),
            CommandProcessMode::InheritConsole,
        )
        .unwrap(),
        0
    );
    assert!(!fixture.data_root().join("_profile.json").exists());

    assert_eq!(
        run(
            &fixture.context,
            &argv(&[".entry/git/name", "Fixture User"]),
            CommandProcessMode::InheritConsole,
        )
        .unwrap(),
        0
    );
    let EntryProfileState::Ready(profile) =
        EntryProfileStore::new(&fixture.context.swawkit_home, fixture.data_root()).read()
    else {
        panic!("expected ready profile");
    };
    assert_eq!(profile.record().git.name, "Fixture User");

    assert_eq!(
        run(
            &fixture.context,
            &argv(&[".dev/bun/mode", "disabled"]),
            CommandProcessMode::InheritConsole,
        )
        .unwrap(),
        0
    );
    let EntryProfileState::Ready(profile) =
        EntryProfileStore::new(&fixture.context.swawkit_home, fixture.data_root()).read()
    else {
        panic!("expected ready profile");
    };
    assert_eq!(profile.record().development.bun.mode, "disabled");

    let before_invalid_update = fs::read(fixture.data_root().join("_profile.json")).unwrap();
    let invalid_update = run(
        &fixture.context,
        &argv(&[".entry/git/unknown", "value"]),
        CommandProcessMode::InheritConsole,
    )
    .unwrap_err();
    assert!(invalid_update.to_string().contains("command not found"));
    assert_eq!(
        fs::read(fixture.data_root().join("_profile.json")).unwrap(),
        before_invalid_update
    );

    let mut replacement = profile.record().clone();
    replacement.git.name = "Applied User".to_owned();
    let input = fixture.target_project_root.join("profile.json");
    fs::write(&input, serde_json::to_string(&replacement).unwrap()).unwrap();
    assert_eq!(
        run(
            &fixture.context,
            &argv(&[".entry/apply", "--file", "profile.json"]),
            CommandProcessMode::InheritConsole,
        )
        .unwrap(),
        0
    );
    let EntryProfileState::Ready(profile) =
        EntryProfileStore::new(&fixture.context.swawkit_home, fixture.data_root()).read()
    else {
        panic!("expected applied profile");
    };
    assert_eq!(profile.record().git.name, "Applied User");
}
