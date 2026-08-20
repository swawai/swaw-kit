use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use sha2::{Digest, Sha256};
use swawkit_proj::context::EntryContext;
use swawkit_proj::data_root::{ResolveDataRootRequest, resolve_data_root};
use swawkit_proj::entry_config::{
    ENTRY_CONFIG_MAX_BYTES, EntryConfigRecord, EntryConfigState, EntryConfigStore,
};

use super::*;

mod check;
mod control;
mod entry_manager;
mod runs;

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

fn run(
    context: &EntryContext,
    argv: &[OsString],
    process_mode: CommandProcessMode,
) -> Result<i32, CliError> {
    run_with_cancellation(context, argv, process_mode, None)
}

fn write_runtime_fixture(root: &Path, runtime_root: &Path) -> String {
    let bootstrap = root.join("data/proj_cache/bootstrap");
    let tool_root = bootstrap.join("fixture-tools");
    fs::create_dir_all(&tool_root).expect("create Framework Command Runtime tools");
    let tools = [("bun", "1.2.15", "bun.exe"), ("pwsh", "7.6.4", "pwsh.exe")]
        .into_iter()
        .map(|(name, version, file)| {
            let bytes = name.as_bytes();
            fs::write(tool_root.join(file), bytes).expect("write Framework Command Runtime tool");
            serde_json::json!({
                "name": name,
                "version": version,
                "path": format!("fixture-tools/{file}"),
                "length": bytes.len(),
                "sha256": format!("{:x}", Sha256::digest(bytes)),
            })
        })
        .collect::<Vec<_>>();
    let mut command_identity = vec!["swawkit.proj-command-runtime/v1".to_owned()];
    for tool in &tools {
        command_identity.extend([
            tool["name"].as_str().unwrap().to_owned(),
            tool["version"].as_str().unwrap().to_owned(),
            tool["path"].as_str().unwrap().to_owned(),
            tool["length"].as_u64().unwrap().to_string(),
            tool["sha256"].as_str().unwrap().to_owned(),
        ]);
    }
    let command_runtime_id = format!(
        "{:x}",
        Sha256::digest(command_identity.join("\n").as_bytes())
    );
    let command_release = bootstrap
        .join("command-runtimes/releases")
        .join(&command_runtime_id);
    fs::create_dir_all(&command_release).expect("create Framework Command Runtime release");
    fs::write(
        command_release.join("manifest.json"),
        serde_json::to_vec(&serde_json::json!({
            "schema": "swawkit.proj-command-runtime/v1",
            "runtimeId": command_runtime_id,
            "tools": tools,
        }))
        .unwrap(),
    )
    .unwrap();

    let artifacts = [
        ("swawkit-proj-dev.exe", b"dev".as_slice()),
        ("swawkit-proj-host.exe", b"host".as_slice()),
        ("swawkit-proj-module.exe", b"module".as_slice()),
        ("swawkit-proj.exe", b"core".as_slice()),
    ];
    let records = artifacts
        .iter()
        .map(|(name, bytes)| {
            serde_json::json!({
                "name": name,
                "length": bytes.len(),
                "sha256": format!("{:x}", Sha256::digest(bytes)),
            })
        })
        .collect::<Vec<_>>();
    let mut identity = vec![
        "swawkit.proj-release-set/v4".to_owned(),
        command_runtime_id.clone(),
    ];
    for record in &records {
        identity.extend([
            record["name"].as_str().unwrap().to_owned(),
            record["length"].as_u64().unwrap().to_string(),
            record["sha256"].as_str().unwrap().to_owned(),
        ]);
    }
    let release_id = format!("{:x}", Sha256::digest(identity.join("\n").as_bytes()));
    let release = runtime_root.join("releases").join(&release_id);
    fs::create_dir_all(&release).expect("create Runtime release");
    for (name, bytes) in artifacts {
        fs::write(release.join(name), bytes).expect("write Runtime artifact");
    }
    fs::write(
        release.join("manifest.json"),
        serde_json::to_vec(&serde_json::json!({
            "schema": "swawkit.proj-release-set/v4",
            "releaseId": release_id,
            "commandRuntimeId": command_runtime_id,
            "artifacts": records,
        }))
        .unwrap(),
    )
    .unwrap();
    release_id
}

struct Fixture {
    root: PathBuf,
    context: EntryContext,
    project_root: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let workspace_root = Path::new(env!("CARGO_MANIFEST_DIR"))
            .ancestors()
            .nth(3)
            .expect("workspace root");
        let root = workspace_root
            .join("data/proj_cache/tests")
            .join(format!("swawkit-cli-{}-{sequence}", std::process::id()));
        let command_root = root.join("_lib/proj");
        let system_root = command_root.join("system");
        let swaw_module_root = command_root.join("modules");
        let project_root = root.join("project");
        let project_module_root = project_root.join(".swaw");
        let entry_file = root.join("fixture.exe");
        for directory in [
            &system_root,
            &swaw_module_root,
            &project_root,
            &project_module_root,
            entry_file.parent().unwrap(),
        ] {
            fs::create_dir_all(directory).expect("create fixture directory");
        }
        fs::write(&entry_file, "fixture").expect("write entry file");
        let runtime_root = root.join("runtime-fixture");
        let release_id = write_runtime_fixture(&root, &runtime_root);
        let product_executable = runtime_root
            .join("releases")
            .join(&release_id)
            .join("swawkit-proj.exe");
        fs::write(runtime_root.join("current"), format!("{release_id}\n"))
            .expect("write Runtime selector fixture");
        let context = EntryContext {
            swawkit_home: root.clone(),
            data_root: root.join("data/proj.fixture"),
            runtime_root,
            entry_file,
            entry_name: "fixture".to_owned(),
            invocation_directory: project_root.clone(),
            product_executable,
            release_id,
        };
        Self {
            root,
            context,
            project_root,
        }
    }

    fn with_entry_runtime() -> Self {
        let mut fixture = Self::new();
        fixture.initialize();
        let runtime_root = fixture.data_root().join("runtime");
        let release_id = write_runtime_fixture(&fixture.root, &runtime_root);
        fs::write(runtime_root.join("current"), format!("{release_id}\n"))
            .expect("write Entry Runtime selector fixture");
        fixture.context.runtime_root = runtime_root.clone();
        fixture.context.product_executable = runtime_root
            .join("releases")
            .join(&release_id)
            .join("swawkit-proj.exe");
        fixture.context.release_id = release_id;
        fixture
    }

    fn data_root(&self) -> PathBuf {
        self.context.data_root.clone()
    }

    fn bind(&self) {
        self.initialize();
        let resolved = resolve_data_root(ResolveDataRootRequest {
            swawkit_home: &self.context.swawkit_home,
            entry_file: &self.context.entry_file,
        })
        .expect("resolve fixture DataRoot");
        let mut config = EntryConfigRecord::default();
        config.project_root = Some(
            self.project_root
                .to_str()
                .expect("Unicode fixture path")
                .to_owned(),
        );
        EntryConfigStore::new(&self.context.swawkit_home, resolved.path())
            .save(config)
            .expect("save fixture Entry Config");
    }

    fn initialize(&self) {
        fs::create_dir_all(self.data_root()).expect("create fixture DataRoot");
    }

    fn command(&self, address: &str, entry_name: &str, body: &str) -> PathBuf {
        let mut directory = self.context.system_root();
        if !address.is_empty() {
            for segment in address.trim_start_matches('.').split('/') {
                directory.push(segment);
                fs::create_dir_all(&directory).expect("create command directory");
                let manifest = directory.join("swawkit.module.json");
                if !manifest.exists() {
                    fs::write(manifest, r#"{"schema":"swawkit.command-module/v11"}"#)
                        .expect("write command manifest");
                }
            }
        }
        fs::create_dir_all(&directory).expect("create command directory");
        fs::write(directory.join(entry_name), body).expect("write command entry");
        directory
    }

    fn core_command(&self, address: &str, handler: &str) -> PathBuf {
        self.command(
            address,
            "swawkit.module.json",
            &format!(
                "{{\"schema\":\"swawkit.command-module/v11\",\"execution\":{{\"type\":\"core\",\"handler\":\"{handler}\"}}}}"
            ),
        )
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn protocol_help_uses_an_explicitly_initialized_entry_without_entry_config() {
    let fixture = Fixture::new();
    fixture.command("", "run.ps1", "exit 0");
    fs::create_dir_all(fixture.context.system_root().join("_help")).unwrap();
    fs::write(
        fixture.context.system_root().join("_help/zh-CN.txt"),
        "Root help",
    )
    .unwrap();
    fixture.initialize();

    let exit_code = run(
        &fixture.context,
        &argv(&["--help"]),
        CommandProcessMode::InheritConsole,
    )
    .unwrap();

    assert_eq!(exit_code, 0);
    assert!(fixture.data_root().is_dir());
}

#[test]
fn local_help_is_read_only_but_command_owned_help_obeys_command_exit_status() {
    let fixture = Fixture::new();
    let local = fixture.command(".local", "run.cmd", "@exit /b 99\r\n");
    fs::create_dir_all(local.join("_help")).unwrap();
    fs::write(local.join("_help/zh-CN.txt"), "Local help").unwrap();
    fixture.command(
        ".owned",
        "run.cmd",
        "@echo off\r\nif \"%~1\"==\"--help\" exit /b 13\r\nexit /b 99\r\n",
    );
    fixture.initialize();

    assert_eq!(
        run(
            &fixture.context,
            &argv(&[".help", ".local"]),
            CommandProcessMode::InheritConsole,
        )
        .unwrap(),
        0
    );
    fixture.bind();
    let exit_code = run(
        &fixture.context,
        &argv(&[".local", "--help"]),
        CommandProcessMode::InheritConsole,
    )
    .unwrap();
    assert_eq!(exit_code, 99);
    assert_eq!(
        run(
            &fixture.context,
            &argv(&[".owned", "--help"]),
            CommandProcessMode::InheritConsole,
        )
        .unwrap(),
        13
    );
    let unavailable = run(
        &fixture.context,
        &argv(&[".help", ".owned"]),
        CommandProcessMode::InheritConsole,
    )
    .unwrap_err();
    assert!(unavailable.to_string().contains("not enabled"));
    assert!(fixture.data_root().is_dir());
}

#[test]
fn command_execution_reuses_the_initialized_entry_data_root() {
    let fixture = Fixture::new();
    fixture.command(".tool", "run.cmd", "@exit /b 29\r\n");
    fixture.bind();

    for _ in 0..2 {
        assert_eq!(
            run(
                &fixture.context,
                &argv(&[".tool"]),
                CommandProcessMode::InheritConsole,
            )
            .unwrap(),
            29
        );
    }
    assert!(fixture.data_root().is_dir());
}

#[test]
fn invalid_or_unsupported_commands_fail_before_process_execution() {
    let fixture = Fixture::new();
    fixture.command(".future", "run.ts", "");
    fixture.bind();

    let missing = run(
        &fixture.context,
        &argv(&[".missing"]),
        CommandProcessMode::InheritConsole,
    )
    .unwrap_err();
    assert!(missing.to_string().contains("command not found"));
    let product_owned_script = run(
        &fixture.context,
        &argv(&[".future"]),
        CommandProcessMode::InheritConsole,
    )
    .unwrap_err();
    assert!(
        product_owned_script
            .to_string()
            .contains("run.ts is restricted to Module commands")
    );
    assert!(fixture.data_root().is_dir());
}

#[test]
fn files_inside_the_canonical_data_root_do_not_define_runtime_identity() {
    let fixture = Fixture::new();
    fixture.command(".tool", "run.cmd", "@exit /b 0\r\n");
    fixture.bind();
    fs::write(fixture.data_root().join("_entry.json"), b"legacy").unwrap();
    let exit_code = run(
        &fixture.context,
        &argv(&[".tool"]),
        CommandProcessMode::InheritConsole,
    )
    .expect("an unrelated legacy record must not gate a running Entry");
    assert_eq!(exit_code, 0);
}

fn argv(values: &[&str]) -> Vec<OsString> {
    values.iter().map(OsString::from).collect()
}
