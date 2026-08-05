use super::*;

#[test]
fn control_web_command_launches_the_entry_before_profile_gating() {
    let fixture = Fixture::new();
    fixture.core_command("..web", "host.start");
    let mut unexpected_claim =
        |_claim: &DataRootClaim| Err(ClaimApprovalError::new("claim was not expected"));
    let mut launched = false;
    let mut launch_host = |context: &EntryContext| {
        launched = context.entry_file == fixture.context.entry_file;
        Ok(0)
    };

    let exit_code = run_with_host_launcher(
        &fixture.context,
        &argv(&["..web"]),
        None,
        None,
        &mut unexpected_claim,
        &mut launch_host,
    )
    .unwrap();

    assert_eq!(exit_code, 0);
    assert!(launched);
    assert!(!fixture.data_root().join("_profile.json").exists());
}

#[test]
fn host_process_uses_the_shared_core_with_a_clean_launch_envelope() {
    let fixture = Fixture::new();
    let executable = fixture
        .context
        .swawkit_home
        .join("_lib/proj/_bin/swawkit-proj.exe");
    let inherited_names = [
        "SWAWKIT_PROJ_ARGV_PROTOCOL",
        "SWAWKIT_PROJ_ARGV_COUNT",
        "SWAWKIT_PROJ_ARGV_47",
        "SWAWKIT_PROJ_INTERNAL_PS_ARG_8",
        "SWAWKIT_PROJ_INTERNAL_PS_ARGC",
        "SWAWKIT_PROJ_INTERNAL_CMD_ENTRY_PATH",
        "swawkit_proj_argv_48",
        "SWAWKIT_PROJ_BUN_VERSION",
    ]
    .map(OsString::from);

    let command = host_process_command(&fixture.context, &executable, inherited_names);
    assert_eq!(command.get_program(), executable.as_os_str());
    assert_eq!(
        command.get_current_dir(),
        Some(fixture.context.invocation_directory.as_path())
    );
    assert_eq!(command.get_args().count(), 0);

    let environment = command
        .get_envs()
        .map(|(name, value)| (name.to_os_string(), value.map(OsString::from)))
        .collect::<std::collections::BTreeMap<_, _>>();
    for name in [
        "SWAWKIT_HOME",
        "SWAWKIT_PROJ_DATA_ROOT",
        "SWAWKIT_PROJ_TARGET_PROJECT_ROOT",
        "SWAWKIT_PROJ_ARGV_PROTOCOL",
        "SWAWKIT_PROJ_ARGV_COUNT",
        "SWAWKIT_PROJ_ARGV_47",
        "SWAWKIT_PROJ_INTERNAL_PS_ARG_8",
        "SWAWKIT_PROJ_INTERNAL_PS_ARGC",
        "SWAWKIT_PROJ_INTERNAL_CMD_ENTRY_PATH",
        "swawkit_proj_argv_48",
    ] {
        assert_eq!(environment.get(std::ffi::OsStr::new(name)), Some(&None));
    }
    assert_eq!(
        environment.get(std::ffi::OsStr::new(ENTRY_FILE_ENV)),
        Some(&Some(fixture.context.entry_file.as_os_str().to_os_string()))
    );
    assert_eq!(
        environment.get(std::ffi::OsStr::new(LAUNCH_MODE_ENV)),
        Some(&Some(OsString::from("internal-host")))
    );
    assert!(!environment.contains_key(std::ffi::OsStr::new("SWAWKIT_PROJ_BUN_VERSION")));
}

#[test]
fn entry_control_commands_create_and_update_a_profile_before_profile_gating() {
    let fixture = Fixture::new();
    fixture.core_command("..entry", "entry.profile");
    fixture.core_command("..entry.set", "entry.profile.set");
    fixture.core_command("..entry.apply", "entry.profile.apply");
    let global_guard = fixture.context.kernel_root().join("_global");
    fs::create_dir_all(&global_guard).unwrap();
    fs::write(
        global_guard.join("run.core.json"),
        r#"{"schema":"swawkit.core-command/v1","handler":"host.start"}"#,
    )
    .unwrap();
    let mut unexpected_claim =
        |_claim: &DataRootClaim| Err(ClaimApprovalError::new("claim was not expected"));

    assert_eq!(
        run_with_approver(
            &fixture.context,
            &argv(&["..entry", "--json"]),
            None,
            None,
            &mut unexpected_claim,
        )
        .unwrap(),
        0
    );
    assert!(!fixture.data_root().join("_profile.json").exists());

    assert_eq!(
        run_with_approver(
            &fixture.context,
            &argv(&["..entry.set", "git.name", "Fixture User"]),
            None,
            None,
            &mut unexpected_claim,
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

    let mut replacement = profile.record().clone();
    replacement.git.name = "Applied User".to_owned();
    let input = fixture.target_project_root.join("profile.json");
    fs::write(&input, serde_json::to_string(&replacement).unwrap()).unwrap();
    assert_eq!(
        run_with_approver(
            &fixture.context,
            &argv(&["..entry.apply", "--file", "profile.json"]),
            None,
            None,
            &mut unexpected_claim,
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
