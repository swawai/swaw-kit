use super::*;

#[test]
fn preparation_owns_the_adapter_invocation_without_starting_it() {
    let fixture = Fixture::new();
    let directory = fixture.command(
        ".prepared",
        "Set-Content (Join-Path $env:SWAWKIT_PROJ_DATA_ROOT 'must-not-run.txt') 'ran'",
    );
    let catalog = fixture.catalog();
    let context = fixture.context();

    let prepared = CommandExecutor::new(&context, &catalog)
        .prepare(&argv(&[".prepared", "alpha", "two words"]))
        .expect("prepare command recipe");

    assert_eq!(prepared.adapter(), CommandAdapter::Pwsh);
    assert_eq!(prepared.entry_path(), directory.join("run.ps1"));
    assert_eq!(prepared.arguments(), argv(&["alpha", "two words"]));
    assert_eq!(
        prepared.working_directory(),
        fixture.target_project_root.as_path()
    );
    assert_eq!(
        prepared
            .environment()
            .value("SWAWKIT_PROJ_CORE_COMMAND_ADDRESS"),
        Some(Some(OsStr::new(".prepared")))
    );
    let AdapterLaunch::Pwsh(executable) = prepared.adapter_launch() else {
        panic!("PowerShell command must own its resolved adapter executable");
    };
    assert!(executable.is_file());
    assert!(!fixture.data_root.join("must-not-run.txt").exists());
}

#[test]
fn logical_plan_does_not_resolve_a_native_artifact() {
    let fixture = Fixture::new();
    let directory = module_directory(&fixture.swaw_module_root, "planned-native");
    fs::create_dir_all(&directory).unwrap();
    fs::write(
        directory.join("swawkit.module.json"),
        r#"{"schema":"swawkit.command-module/v11","execution":{"type":"native"}}"#,
    )
    .unwrap();
    let catalog = fixture.catalog();
    let context = fixture.context();
    let executor = CommandExecutor::new(&context, &catalog);

    let plan = executor
        .plan(&argv(&["swaw/planned-native"]))
        .expect("logical plan must not inspect the native artifact");
    let error = match executor.materialize(plan) {
        Ok(_) => panic!("adapter materialization unexpectedly resolved a native artifact"),
        Err(error) => error,
    };

    assert!(error.to_string().contains("has not been instantiated"));
}

#[test]
fn isolated_launch_uses_target_cwd_and_overlays_the_supplied_baseline() {
    let fixture = Fixture::new();
    fixture.command(".isolated", "exit 0");
    let catalog = fixture.catalog();
    let context = fixture.context();
    let prepared = CommandExecutor::new(&context, &catalog)
        .prepare(&argv(&[".isolated"]))
        .expect("prepared command");
    let baseline = [
        (OsString::from("SystemRoot"), OsString::from(r"C:\Windows")),
        (
            OsString::from("SWAWKIT_HOME"),
            OsString::from(r"C:\stale-host"),
        ),
    ];

    let launch = prepared
        .materialize_process_launch_with_baseline(&baseline)
        .expect("isolated process launch");
    let command = launch.command();

    assert_eq!(
        command.get_current_dir(),
        Some(fixture.target_project_root.as_path())
    );
    assert_eq!(
        command_environment(command, "SystemRoot"),
        Some(r"C:\Windows")
    );
    assert_eq!(
        command_environment(command, "SWAWKIT_HOME"),
        Some(fixture.root.to_str().unwrap())
    );
    assert_eq!(
        command_environment(command, "SWAWKIT_PROJ_CORE_COMMAND_INVOCATION_DIR"),
        Some(fixture.target_project_root.to_str().unwrap())
    );
    assert_eq!(
        command_environment(command, "SWAWKIT_PROJ_CORE_COMMAND_ADAPTER_PWSH_ENTRY_PATH"),
        Some(prepared.entry_path().to_str().unwrap())
    );
    assert_eq!(launch.base_creation_flags(), 0);
}

#[test]
fn cmd_launch_pins_comspec_from_the_isolated_baseline() {
    let fixture = Fixture::new();
    let directory = command_directory(&fixture.system_root, ".batch-launch");
    fs::create_dir_all(&directory).unwrap();
    fs::write(
        directory.join("swawkit.module.json"),
        r#"{"schema":"swawkit.command-module/v11"}"#,
    )
    .unwrap();
    fs::write(directory.join("run.cmd"), "@exit /b 0\r\n").unwrap();
    let catalog = fixture.catalog();
    let context = fixture.context();
    let prepared = CommandExecutor::new(&context, &catalog)
        .prepare(&argv(&[".batch-launch"]))
        .expect("prepared Cmd command");
    let comspec = PathBuf::from(env::var_os("SystemRoot").unwrap()).join("System32/cmd.exe");
    let baseline = [(OsString::from("comspec"), comspec.as_os_str().to_owned())];

    let launch = prepared
        .materialize_process_launch_with_baseline(&baseline)
        .expect("Cmd process launch");

    assert_eq!(launch.command().get_program(), comspec.as_os_str());
    let error = match prepared.materialize_process_launch_with_baseline(&[]) {
        Ok(_) => panic!("ambient ComSpec was unexpectedly consulted"),
        Err(error) => error,
    };
    assert_eq!(
        error.to_string(),
        "the Windows command processor is unavailable"
    );
}

fn command_environment<'a>(command: &'a std::process::Command, name: &str) -> Option<&'a str> {
    command.get_envs().find_map(|(candidate, value)| {
        candidate
            .to_str()
            .is_some_and(|candidate| candidate.eq_ignore_ascii_case(name))
            .then(|| value.and_then(OsStr::to_str))
            .flatten()
    })
}
