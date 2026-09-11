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
    assert_eq!(prepared.entry_path(), directory.join("execute/run.ps1"));
    assert_eq!(prepared.arguments(), argv(&["alpha", "two words"]));
    assert_eq!(prepared.working_directory(), fixture.project_root.as_path());
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
    let execute = directory.join("execute");
    fs::create_dir_all(&execute).unwrap();
    fs::write(
        execute.join("swawkit.facet.json"),
        r#"{"schema":"swawkit.facet/v1","kind":"operation"}"#,
    )
    .unwrap();
    fs::write(
        execute.join("swawkit.execution.json"),
        r#"{"schema":"swawkit.facet-execution/v2","implementation":{"type":"native"}}"#,
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
        Some(fixture.project_root.as_path())
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
        Some(fixture.project_root.to_str().unwrap())
    );
    assert_eq!(
        command_environment(command, "SWAWKIT_PROJ_CORE_COMMAND_ADAPTER_PWSH_ENTRY_PATH"),
        Some(prepared.entry_path().to_str().unwrap())
    );
    assert_eq!(launch.base_creation_flags(), 0);
}

#[test]
fn isolated_system_launch_removes_dirty_retired_and_project_environment() {
    let fixture = Fixture::new();
    let dirty_names = EXPECTED_RETIRED_COMMAND_ENVIRONMENT
        .iter()
        .chain(EXPECTED_CONDITIONAL_PROJECT_ENVIRONMENT.iter())
        .copied()
        .collect::<Vec<_>>();
    let names = dirty_names
        .iter()
        .map(|name| format!("'{name}'"))
        .collect::<Vec<_>>()
        .join(", ");
    fixture.command(
        ".isolated-clean",
        &format!(
            r#"$names = [string[]]@({names})
foreach ($name in $names) {{
    if ($null -ne [Environment]::GetEnvironmentVariable($name, 'Process')) {{
        [Console]::Error.WriteLine('leaked parent environment: ' + $name)
        exit 91
    }}
}}
exit 0"#
        ),
    );
    let catalog = fixture.catalog();
    let context = fixture.context();
    let prepared = CommandExecutor::new(&context, &catalog)
        .prepare(&argv(&[".isolated-clean"]))
        .expect("prepared System command");
    let mut baseline = vec![(
        OsString::from("SystemRoot"),
        env::var_os("SystemRoot").expect("SystemRoot"),
    )];
    baseline.extend(
        dirty_names
            .iter()
            .map(|name| (OsString::from(name), OsString::from("stale-parent-value"))),
    );

    let launch = prepared
        .materialize_process_launch_with_baseline(&baseline)
        .expect("isolated System process launch");
    let status = launch.status_for_test().expect("run isolated System child");

    assert_eq!(status.code(), Some(0));
}

#[test]
fn isolated_project_launch_replaces_dirty_conditional_project_environment() {
    let fixture = Fixture::new();
    let directory = module_directory(&fixture.project_module_root, "build");
    let execute = directory.join("execute");
    fs::create_dir_all(&execute).expect("create project execute Facet");
    fs::write(
        execute.join("swawkit.facet.json"),
        r#"{"schema":"swawkit.facet/v1","kind":"operation"}"#,
    )
    .expect("write project command manifest");
    fs::write(
        execute.join("run.ps1"),
        r#"$output = Join-Path $env:SWAWKIT_HOME 'project-environment.txt'
[IO.File]::WriteAllLines(
    $output,
    [string[]]@(
        $env:SWAWKIT_PROJ_PROJECT_ROOT,
        $env:SWAWKIT_PROJ_PROJECT_MODULE_ROOT
    )
)
exit 0"#,
    )
    .expect("write project command entry");
    let catalog = fixture.catalog();
    let context = fixture.context();
    let prepared = CommandExecutor::new(&context, &catalog)
        .prepare(&argv(&["project/build"]))
        .expect("prepared project command");
    let mut baseline = vec![(
        OsString::from("SystemRoot"),
        env::var_os("SystemRoot").expect("SystemRoot"),
    )];
    baseline.extend(
        EXPECTED_CONDITIONAL_PROJECT_ENVIRONMENT
            .map(|name| (OsString::from(name), OsString::from("stale-parent-value"))),
    );

    let launch = prepared
        .materialize_process_launch_with_baseline(&baseline)
        .expect("isolated project process launch");
    let status = launch
        .status_for_test()
        .expect("run isolated project child");
    assert_eq!(status.code(), Some(0));
    let output = fs::read_to_string(fixture.root.join("project-environment.txt"))
        .expect("read projected project environment");
    let values = output.lines().collect::<Vec<_>>();

    assert_eq!(
        values,
        [
            fixture.project_root.to_str().expect("project root UTF-8"),
            fixture
                .project_module_root
                .to_str()
                .expect("project Module root UTF-8")
        ]
    );
}

#[test]
fn cmd_launch_pins_comspec_from_the_isolated_baseline() {
    let fixture = Fixture::new();
    let directory = command_directory(&fixture.system_root, ".batch-launch");
    let execute = directory.join("execute");
    fs::create_dir_all(&execute).unwrap();
    fs::write(
        execute.join("swawkit.facet.json"),
        r#"{"schema":"swawkit.facet/v1","kind":"operation"}"#,
    )
    .unwrap();
    fs::write(execute.join("run.cmd"), "@exit /b 0\r\n").unwrap();
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
