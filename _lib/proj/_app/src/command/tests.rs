use std::collections::BTreeMap;
use std::env;
use std::ffi::{OsStr, OsString};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use crate::{
    catalog::{CatalogSnapshot, CommandAdapter},
    command_runtime::{COMMAND_RUNTIME_SCHEMA, CommandRuntime},
    launch::{ENTRY_FILE_ENV, LAUNCH_MODE_ENV},
    profile::EntryProfileRecord,
};
use serde_json::Value;
use sha2::{Digest, Sha256};

use super::{
    CommandExecutionContext, CommandExecutor, CommandProcessMode, Invocation, ProcessEnvironment,
    ResolvedCommand,
    process::{AdapterLaunch, run_process},
    validate_dev_executable, validate_module_executable,
};

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

fn write_json(path: &Path, value: &serde_json::Value) {
    fs::create_dir_all(path.parent().expect("JSON parent")).expect("create JSON parent");
    fs::write(path, serde_json::to_vec(value).expect("serialize JSON")).expect("write JSON");
}

fn link_directory(source: &Path, target: &Path) {
    fs::create_dir_all(target).expect("create linked fixture directory");
    for entry in fs::read_dir(source).expect("read fixture source directory") {
        let entry = entry.expect("fixture source entry");
        let name = entry.file_name();
        if name == ".swawkit-dev-install.json" {
            continue;
        }
        let source = entry.path();
        let target = target.join(name);
        if entry.file_type().expect("fixture source type").is_dir() {
            link_directory(&source, &target);
        } else {
            fs::hard_link(&source, &target).expect("link managed PowerShell fixture file");
        }
    }
}

fn command_runtime_fixture(root: &Path, pwsh_source: &Path) -> String {
    let bootstrap = root.join("data/proj_cache/bootstrap");
    let tools_root = bootstrap.join("fixture-tools");
    let pwsh_root = tools_root.join("pwsh");
    link_directory(
        pwsh_source.parent().expect("PowerShell fixture root"),
        &pwsh_root,
    );
    fs::create_dir_all(&tools_root).expect("create Command Runtime fixture root");
    fs::write(tools_root.join("bun.exe"), b"bun").expect("write Bun fixture");
    let definitions = [
        ("bun", "1.2.15", "fixture-tools/bun.exe"),
        ("pwsh", "7.6.4", "fixture-tools/pwsh/pwsh.exe"),
    ];
    let records = definitions
        .iter()
        .map(|(name, version, relative)| {
            let bytes = fs::read(bootstrap.join(relative)).expect("read Command Runtime tool");
            serde_json::json!({
                "name": name,
                "version": version,
                "path": relative,
                "length": bytes.len(),
                "sha256": format!("{:x}", Sha256::digest(&bytes)),
            })
        })
        .collect::<Vec<_>>();
    let mut identity = vec![COMMAND_RUNTIME_SCHEMA.to_owned()];
    for record in &records {
        identity.extend([
            record["name"].as_str().unwrap().to_owned(),
            record["version"].as_str().unwrap().to_owned(),
            record["path"].as_str().unwrap().to_owned(),
            record["length"].as_u64().unwrap().to_string(),
            record["sha256"].as_str().unwrap().to_owned(),
        ]);
    }
    let runtime_id = format!("{:x}", Sha256::digest(identity.join("\n").as_bytes()));
    let release = bootstrap
        .join("command-runtimes/releases")
        .join(&runtime_id);
    fs::create_dir_all(&release).expect("create Command Runtime release");
    write_json(
        &release.join("manifest.json"),
        &serde_json::json!({
            "schema": COMMAND_RUNTIME_SCHEMA,
            "runtimeId": runtime_id,
            "tools": records,
        }),
    );
    runtime_id
}

struct Fixture {
    root: PathBuf,
    command_root: PathBuf,
    system_root: PathBuf,
    swaw_module_root: PathBuf,
    target_project_root: PathBuf,
    project_module_root: PathBuf,
    data_root: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let workspace_root = Path::new(env!("CARGO_MANIFEST_DIR"))
            .ancestors()
            .nth(3)
            .expect("workspace root");
        let root = workspace_root
            .join("data/proj_cache/tests/command %PATH% & fixtures")
            .join(format!("swawkit-command-{}-{sequence}", std::process::id()));
        let command_root = root.join("_lib/proj");
        let system_root = command_root.join("system");
        let swaw_module_root = command_root.join("modules");
        let target_project_root = root.join("project");
        let project_module_root = target_project_root.join(".swaw");
        let data_root = root.join("data");
        for directory in [
            &command_root,
            &system_root,
            &swaw_module_root,
            &target_project_root,
            &project_module_root,
            &data_root,
        ] {
            fs::create_dir_all(directory).expect("create fixture directory");
        }
        fs::write(root.join("swawkit-proj-dev.exe"), "fixture").expect("write Dev fixture");
        fs::write(root.join("swawkit-proj-module.exe"), "fixture")
            .expect("write module Runtime Component fixture");
        Self {
            root,
            command_root,
            system_root,
            swaw_module_root,
            target_project_root,
            project_module_root,
            data_root,
        }
    }

    fn command(&self, address: &str, script: &str) -> PathBuf {
        let directory = command_directory(&self.system_root, address);
        fs::create_dir_all(&directory).expect("create command directory");
        fs::write(
            directory.join("swawkit.module.json"),
            r#"{"schema":"swawkit.command-module/v11"}"#,
        )
        .expect("write command manifest");
        fs::write(directory.join("run.ps1"), script).expect("write command entry");
        directory
    }

    fn catalog(&self) -> CatalogSnapshot {
        CatalogSnapshot::discover_roots(
            &self.system_root,
            &self.swaw_module_root,
            &self.project_module_root,
            "fixture",
        )
        .expect("discover catalog")
    }

    fn context(&self) -> CommandExecutionContext {
        let mut profile = EntryProfileRecord::default();
        profile.development.bun.mode = "disabled".to_owned();
        profile.development.pwsh.mode = "disabled".to_owned();
        profile.development.pwsh.version = "7.6.4".to_owned();
        profile.development.msvc.mode = "disabled".to_owned();
        profile.development.rust.mode = "disabled".to_owned();
        let environment_input_revision = profile.environment_input_revision();
        let source = Path::new(env!("CARGO_MANIFEST_DIR"))
            .ancestors()
            .nth(3)
            .expect("workspace root")
            .join("data/proj.swawkit/modules/system/dev/setup/export/pwsh/installs/7.6.4/pwsh.exe");
        let command_runtime_id = command_runtime_fixture(&self.root, &source);
        CommandExecutionContext {
            swawkit_home: self.root.clone(),
            command_root: self.command_root.clone(),
            system_root: self.system_root.clone(),
            target_project_root: self.target_project_root.clone(),
            module_roots: BTreeMap::from([
                ("swaw".to_owned(), self.swaw_module_root.clone()),
                ("project".to_owned(), self.project_module_root.clone()),
            ]),
            data_root: self.data_root.clone(),
            entry_name: "fixture".to_owned(),
            entry_file: self.root.join("fixture.exe"),
            invocation_directory: self.target_project_root.clone(),
            dev_executable: self.root.join("swawkit-proj-dev.exe"),
            module_executable: self.root.join("swawkit-proj-module.exe"),
            command_runtime_id,
            profile,
            environment_input_revision,
            profile_revision: format!("sha256-{}", "0".repeat(64)),
            process_mode: CommandProcessMode::InheritConsole,
        }
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn invocation_preserves_help_markers_for_the_cli_protocol_boundary() {
    let fixture = Fixture::new();
    let local = fixture.command(".local", "exit 0");
    fs::create_dir_all(local.join("_help")).unwrap();
    fs::write(local.join("_help/zh-CN.txt"), "Local help").unwrap();
    fixture.command(".owned", "exit 0");
    let catalog = fixture.catalog();

    let local = Invocation::resolve(&catalog, &argv(&[".local", "--help"])).unwrap();
    assert_eq!(local.command.address, ".local");
    assert_eq!(local.arguments, argv(&["--help"]));

    let owned = Invocation::resolve(&catalog, &argv(&[".owned", "--help"])).unwrap();
    assert_eq!(owned.command.address, ".owned");
    assert_eq!(owned.arguments, argv(&["--help"]));
}

#[test]
fn process_environment_is_declarative() {
    let fixture = Fixture::new();
    fixture.command(".tool", "exit 0");
    let command = ResolvedCommand::from_catalog(&fixture.catalog(), ".tool").unwrap();
    let context = fixture.context();

    let mut run =
        ProcessEnvironment::for_command(&context, &command).expect("build run environment");
    assert_eq!(
        run.value("SWAWKIT_PROJ_CORE_COMMAND_PROTOCOL"),
        Some(Some(OsStr::new("2")))
    );
    assert_eq!(
        run.value("SWAWKIT_PROJ_CORE_COMMAND_EVENT_PROTOCOL"),
        Some(Some(OsStr::new("swawkit.command-event-frame/v1")))
    );
    assert_eq!(run.value(ENTRY_FILE_ENV), Some(None));
    assert_eq!(run.value(LAUNCH_MODE_ENV), Some(None));
    assert_eq!(run.value("SWAWKIT_PROJ_CORE_COMMAND_PHASE"), Some(None));
    assert_eq!(
        run.value("SWAWKIT_PROJ_CORE_COMMAND_GUARD_SCOPE"),
        Some(None)
    );
    assert_eq!(
        run.value("SWAWKIT_PROJ_CORE_COMMAND_ENTRY_FILE"),
        Some(Some(context.entry_file.as_os_str()))
    );
    assert_eq!(
        run.value("SWAWKIT_PROJ_CORE_DEV_EXECUTABLE"),
        Some(Some(context.dev_executable.as_os_str()))
    );
    assert_eq!(
        run.value("SWAWKIT_PROJ_CORE_COMMAND_ENVIRONMENT_INPUT_REVISION"),
        Some(Some(OsStr::new(&context.environment_input_revision)))
    );
    assert_eq!(
        run.value("SWAWKIT_PROJ_CORE_COMMAND_PROFILE_REVISION"),
        Some(Some(OsStr::new(&context.profile_revision)))
    );
    assert_eq!(
        run.value("SWAWKIT_PROJ_CORE_COMMAND_ADDRESS"),
        Some(Some(OsStr::new(".tool")))
    );
    assert_eq!(
        run.value("SWAWKIT_PROJ_CORE_COMMAND_DATA_ROOT"),
        Some(Some(
            fixture
                .data_root
                .join("modules")
                .join("system")
                .join("tool")
                .as_os_str()
        ))
    );
    assert_eq!(
        run.value("SWAWKIT_PROJ_TARGET_PROJECT_ROOT"),
        Some(Some(fixture.target_project_root.as_os_str()))
    );
    assert_eq!(
        run.value("SWAWKIT_PROJ_SYSTEM_ROOT"),
        Some(Some(fixture.system_root.as_os_str()))
    );
    assert_eq!(
        run.value("SWAWKIT_HOME"),
        Some(Some(fixture.root.as_os_str()))
    );
    assert_eq!(
        run.value("SWAWKIT_PROJ_BUN_VERSION"),
        Some(Some(OsStr::new("1.2.15")))
    );
    assert_eq!(run.value("SWAWKIT_PROJ_GIT_ID_EMAIL"), Some(None));
    for name in [
        "SWAWKIT_PROJ_CORE_COMMAND_OWNER_ADDRESS",
        "SWAWKIT_PROJ_CORE_COMMAND_OWNER_DIR",
        "SWAWKIT_PROJ_CORE_COMMAND_OWNER_DATA_ROOT",
    ] {
        assert_eq!(run.value(name), Some(None));
    }
    let owner_data_root = fixture.data_root.join("modules/swaw/owner");
    run.apply_native_owner("swaw/owner", &fixture.swaw_module_root, &owner_data_root);
    assert_eq!(
        run.value("SWAWKIT_PROJ_CORE_COMMAND_OWNER_ADDRESS"),
        Some(Some(OsStr::new("swaw/owner")))
    );
    assert_eq!(
        run.value("SWAWKIT_PROJ_CORE_COMMAND_OWNER_DIR"),
        Some(Some(fixture.swaw_module_root.as_os_str()))
    );
    assert_eq!(
        run.value("SWAWKIT_PROJ_CORE_COMMAND_OWNER_DATA_ROOT"),
        Some(Some(owner_data_root.as_os_str()))
    );
}

#[test]
fn runtime_dev_validation_rejects_a_missing_product() {
    let fixture = Fixture::new();
    fixture.command(".tool", "exit 0");
    let context = fixture.context();
    fs::remove_file(&context.dev_executable).expect("remove Dev fixture");

    let error = validate_dev_executable(&context.dev_executable)
        .expect_err("missing Dev product must reject command execution");

    assert!(
        error
            .to_string()
            .contains("Runtime Component product 'dev' is unavailable")
    );
}

#[test]
fn runtime_component_rejects_a_missing_module_product() {
    let fixture = Fixture::new();
    let context = fixture.context();
    fs::remove_file(&context.module_executable).expect("remove module product fixture");

    let error = validate_module_executable(&context.module_executable)
        .expect_err("missing module product must reject Runtime execution");

    assert!(
        error
            .to_string()
            .contains("Runtime Component product 'module' is unavailable")
    );
}

#[test]
fn command_data_roots_are_isolated_by_structured_identity() {
    let fixture = Fixture::new();
    fixture.command(".tool", "exit 0");
    let control = fixture.system_root.join("entry");
    fs::create_dir_all(&control).unwrap();
    fs::write(
        control.join("swawkit.module.json"),
        r#"{"schema":"swawkit.command-module/v11","execution":{"type":"core","handler":"entry.profile"}}"#,
    )
    .unwrap();
    let action = fixture.project_module_root.join("build");
    fs::create_dir_all(&action).unwrap();
    fs::write(
        action.join("swawkit.module.json"),
        r#"{"schema":"swawkit.command-module/v11"}"#,
    )
    .unwrap();
    fs::write(action.join("run.ps1"), "exit 0").unwrap();
    let catalog = fixture.catalog();
    let context = fixture.context();

    for (address, space, relative) in [
        (".tool", "system", "tool"),
        (".entry", "system", "entry"),
        ("project/build", "project", "build"),
    ] {
        let command = ResolvedCommand::from_catalog(&catalog, address).unwrap();
        let environment = ProcessEnvironment::for_command(&context, &command).unwrap();
        assert_eq!(
            environment.value("SWAWKIT_PROJ_CORE_COMMAND_DATA_ROOT"),
            Some(Some(
                fixture
                    .data_root
                    .join("modules")
                    .join(space)
                    .join(relative)
                    .as_os_str()
            ))
        );
    }
}

#[test]
fn framework_pwsh_pipeline_ignores_target_dev_selection_and_preserves_invocation() {
    let fixture = Fixture::new();
    let target = r#"
$adapterNames = @([Environment]::GetEnvironmentVariables().Keys |
    Where-Object {
        ([string]$_).StartsWith(
            'SWAWKIT_PROJ_CORE_COMMAND_ADAPTER_',
            [StringComparison]::OrdinalIgnoreCase
        )
    })
if ($adapterNames.Count -ne 0) {
    throw ('PowerShell adapter variables leaked: ' +
        ([string[]]$adapterNames -join ', '))
}

$encoded = @($args | ForEach-Object {
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$_))
}) -join ','
$line = 'target|' + $env:SWAWKIT_PROJ_CORE_COMMAND_ADDRESS + '|' + $encoded
$tracePath = Join-Path $env:SWAWKIT_PROJ_DATA_ROOT 'trace.txt'
[IO.File]::AppendAllText($tracePath, $line + [Environment]::NewLine)
exit 23
"#;
    fixture.command(".tool", target);
    let catalog = fixture.catalog();
    let context = fixture.context();
    let exit_code = CommandExecutor::new(&context, &catalog)
        .execute(&argv(&[".tool", "", "a b", "quote\"x"]))
        .unwrap();

    assert_eq!(exit_code, 23);
    let lines = fs::read_to_string(fixture.data_root.join("trace.txt")).unwrap();
    let lines: Vec<&str> = lines.lines().collect();
    assert_eq!(lines, ["target|.tool|,YSBi,cXVvdGUieA=="]);
}

#[test]
fn command_runtime_rejects_a_tampered_tool_when_that_adapter_is_selected() {
    let fixture = Fixture::new();
    let context = fixture.context();
    let runtime = CommandRuntime::open(&context.swawkit_home, &context.command_runtime_id)
        .expect("open Command Runtime before tool selection");
    fs::write(
        fixture
            .root
            .join("data/proj_cache/bootstrap/fixture-tools/bun.exe"),
        b"bad",
    )
    .expect("tamper Bun fixture without changing its length");

    let error = runtime
        .tool(&context.swawkit_home, "bun")
        .expect_err("a selected Command Runtime tool must be hashed before launch");
    assert!(error.to_string().contains("SHA-256"));
}

#[test]
fn journaled_execution_persists_target_output_in_the_module_data_root() {
    let fixture = Fixture::new();
    fixture.command(
        ".journal",
        r#"[Console]::Out.WriteLine('target out'); [Console]::Error.WriteLine(([char]0x1e) + 'swawkit-event-v1 {"schema":"swawkit.command-event/v1","kind":"progress","id":"download:fixture.zip","state":"completed","current":42,"total":42,"unit":"bytes","message":"Downloaded fixture.zip"}'); [Console]::Error.WriteLine('target err'); exit 4"#,
    );
    let catalog = fixture.catalog();

    let exit_code = CommandExecutor::new(&fixture.context(), &catalog)
        .execute_journaled(&argv(&[".journal", "argument-not-persisted"]))
        .unwrap();

    assert_eq!(exit_code, 4);
    let runs_root = fixture.data_root.join("modules/system/journal/_runs");
    let run_root = fs::read_dir(runs_root)
        .unwrap()
        .next()
        .expect("one command journal")
        .unwrap()
        .path();
    let state: Value = serde_json::from_slice(&fs::read(run_root.join("_state.json")).unwrap())
        .expect("run journal state");
    assert_eq!(state["address"], ".journal");
    assert_eq!(state["source"], "cli");
    assert_eq!(state["status"], "exited");
    assert_eq!(state["exitCode"], 4);
    assert_eq!(state["argumentCount"], 1);
    let events = fs::read_to_string(run_root.join("events.jsonl")).unwrap();
    assert!(events.contains("\"phase\":\"run\""));
    assert!(events.contains("\"kind\":\"progress\""));
    assert!(events.contains("\"id\":\"download:fixture.zip\""));
    assert!(events.contains("target err"));
    assert!(!events.contains("swawkit-event-v1"));
    assert!(!events.contains("argument-not-persisted"));
}

#[test]
fn cmd_adapter_allows_only_one_standalone_help_selector() {
    let fixture = Fixture::new();
    let directory = command_directory(&fixture.system_root, ".batch");
    fs::create_dir_all(&directory).unwrap();
    fs::write(
        directory.join("swawkit.module.json"),
        r#"{"schema":"swawkit.command-module/v11"}"#,
    )
    .unwrap();
    fs::write(
        directory.join("run.cmd"),
        "@echo off\r\n\
         if defined SWAWKIT_PROJ_CORE_COMMAND_ADAPTER_CMD_ENTRY_PATH exit /b 91\r\n\
         > \"%SWAWKIT_PROJ_DATA_ROOT%\\cmd.txt\" \
         echo %~1^|%SWAWKIT_PROJ_CORE_COMMAND_ADDRESS%\r\n\
         exit /b 31\r\n",
    )
    .unwrap();
    let catalog = fixture.catalog();
    let context = fixture.context();
    let executor = CommandExecutor::new(&context, &catalog);

    assert_eq!(executor.execute(&argv(&[".batch", "--help"])).unwrap(), 31);
    assert_eq!(
        fs::read_to_string(fixture.data_root.join("cmd.txt"))
            .unwrap()
            .trim(),
        "--help|.batch"
    );
    let error = executor
        .execute(&argv(&[".batch", "one", "two"]))
        .unwrap_err();
    assert!(error.to_string().contains("one standalone help selector"));
}

#[test]
fn pwsh_adapter_propagates_a_native_child_exit_code() {
    let fixture = Fixture::new();
    fixture.command(".native", "& $env:ComSpec /d /c exit 12");
    let catalog = fixture.catalog();

    let exit_code = CommandExecutor::new(&fixture.context(), &catalog)
        .execute(&argv(&[".native"]))
        .unwrap();

    assert_eq!(exit_code, 12);
}

#[test]
fn exe_adapter_returns_the_exact_child_exit_code() {
    let fixture = Fixture::new();
    let comspec = env::var_os("ComSpec").expect("ComSpec");
    let environment = ProcessEnvironment::default();
    let arguments = argv(&["/d", "/c", "exit", "9"]);

    let exit_code = run_process(
        CommandAdapter::Exe,
        Path::new(&comspec),
        &arguments,
        &fixture.target_project_root,
        &AdapterLaunch::Direct,
        &environment,
        CommandProcessMode::InheritConsole,
    )
    .unwrap();

    assert_eq!(exit_code, 9);
}

fn argv(values: &[&str]) -> Vec<OsString> {
    values.iter().map(OsString::from).collect()
}

fn command_directory(command_root: &Path, address: &str) -> PathBuf {
    if address.is_empty() {
        return command_root.to_owned();
    }
    let mut segments = address.trim_start_matches('.').split('/');
    let mut directory = command_root.join(segments.next().unwrap());
    for segment in segments {
        directory.push(segment);
    }
    directory
}

fn module_directory(module_root: &Path, path: &str) -> PathBuf {
    path.split('/')
        .fold(module_root.to_owned(), |root, segment| root.join(segment))
}

mod dependency;
mod native;
mod prepared;
