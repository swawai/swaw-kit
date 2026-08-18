use std::env;
use std::ffi::OsString;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::thread;
use std::time::{Duration, Instant};

use swawkit_proj_protocol::CommandRelease;
use swawkit_proj_protocol::serde::{self, Deserialize};
use swawkit_proj_protocol::serde_json;

use crate::filesystem::{
    ExclusiveFileLock, ensure_directory, read_regular_file, regular_directory,
};
use crate::manifest::{NativeDomain, discover_native_domain};
use crate::release_store::{prepare_native_root, publish};
use crate::snapshot::build_input_snapshot;
use crate::transport::CommandContext;

const DESCRIPTION_ARGUMENT: &str = "--swawkit-describe";
const DESCRIPTION_SCHEMA: &str = "swawkit.native-command-description/v1";
const MAX_DESCRIPTION_BYTES: usize = 64 * 1024;
const MAX_EXECUTABLE_BYTES: u64 = 512 * 1024 * 1024;
const DESCRIPTION_TIMEOUT: Duration = Duration::from_secs(10);

pub(crate) fn run(context: &CommandContext, arguments: &[OsString]) -> Result<(), String> {
    let [address] = arguments else {
        return Err(".module/instantiate requires exactly one Module command address".to_owned());
    };
    let address = address
        .to_str()
        .ok_or_else(|| "Module command address must be valid Unicode".to_owned())?;
    let initial = discover_native_domain(&context.module_roots, address)?;
    let native_root = prepare_native_root(&context.data_root, &initial.owner_address)?;
    let locks = ensure_directory(&native_root, ["locks"], "native module locks")?;
    let _lock =
        ExclusiveFileLock::acquire(&locks.join("instantiate.lock"), Duration::from_secs(600))?;

    let before_domain = discover_native_domain(&context.module_roots, address)?;
    if before_domain.owner_address != initial.owner_address {
        return Err(format!(
            "native owner for '{address}' changed while its instantiate lock was being acquired; retry the command"
        ));
    }
    let before_contract = before_domain.execution_contract_revision()?;
    let before = build_input_snapshot(
        &before_domain.owner_directory,
        &before_contract,
        &before_domain.nested_owner_directories,
    )?;
    let work = ensure_directory(
        &native_root,
        ["work", "cargo-target"],
        "native module Cargo target",
    )?;
    let cargo = managed_cargo()?;
    let candidate = build_candidate(&before_domain.owner_directory, &work, &cargo)?;
    let executable =
        read_regular_file(&candidate, "compiled native command", MAX_EXECUTABLE_BYTES)?;
    if executable.is_empty() {
        return Err(format!(
            "compiled native command is empty: {}",
            candidate.display()
        ));
    }
    validate_description(&candidate, &before_domain)?;
    let executable_after =
        read_regular_file(&candidate, "compiled native command", MAX_EXECUTABLE_BYTES)?;
    if executable_after != executable {
        return Err(format!(
            "compiled native command changed while its description was being validated: {}",
            candidate.display()
        ));
    }

    let after_domain = discover_native_domain(&context.module_roots, address)?;
    let after_contract = after_domain.execution_contract_revision()?;
    let after = build_input_snapshot(
        &after_domain.owner_directory,
        &after_contract,
        &after_domain.nested_owner_directories,
    )?;
    if after_domain.owner_address != before_domain.owner_address
        || after_contract != before_contract
        || after.revision != before.revision
    {
        return Err(format!(
            "native module '{}' changed while it was being built; no release was published",
            before_domain.owner_address
        ));
    }
    let release = CommandRelease::new(
        before_domain.owner_address.clone(),
        before.revision,
        before_contract,
        before_domain.commands(),
        &executable,
    )
    .map_err(|error| error.to_string())?;
    let publication = publish(&native_root, &release, &executable)?;
    let action = if publication.changed {
        "published"
    } else {
        "already current"
    };
    println!(
        "Native module target {}: {action} {}",
        before_domain.owner_address, publication.release_id
    );
    Ok(())
}

fn managed_cargo() -> Result<PathBuf, String> {
    let rustc = env::var_os("RUSTC")
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            "managed Rust is unavailable; enable it and publish .dev/setup first".to_owned()
        })?;
    let rustc = PathBuf::from(rustc);
    if !rustc.is_absolute() || rustc.file_name().and_then(|name| name.to_str()) != Some("rustc.exe")
    {
        return Err(format!(
            "managed RUSTC must be an absolute rustc.exe path: {}",
            rustc.display()
        ));
    }
    read_regular_file(&rustc, "managed Rust compiler", MAX_EXECUTABLE_BYTES)?;
    let cargo = rustc
        .parent()
        .ok_or_else(|| "managed RUSTC has no parent directory".to_owned())?
        .join("cargo.exe");
    read_regular_file(&cargo, "managed Cargo", MAX_EXECUTABLE_BYTES)?;
    Ok(cargo)
}

fn build_candidate(owner: &Path, target: &Path, cargo: &Path) -> Result<PathBuf, String> {
    regular_directory(owner, "native owner source directory")?;
    regular_directory(target, "native module Cargo target")?;
    let manifest = owner.join("Cargo.toml");
    read_regular_file(&manifest, "native module Cargo manifest", 1024 * 1024)?;
    let release_directory = target.join("release");
    match fs::symlink_metadata(&release_directory) {
        Ok(_) => regular_directory(&release_directory, "native module Cargo release output")?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => {
            return Err(format!(
                "cannot inspect native module Cargo release output '{}': {error}",
                release_directory.display()
            ));
        }
    }
    let candidate = release_directory.join("run.exe");
    remove_stale_candidate(&candidate)?;
    let status = Command::new(cargo)
        .args(["build", "--locked", "--release", "--manifest-path"])
        .arg(&manifest)
        .arg("--target-dir")
        .arg(target)
        .current_dir(owner)
        .status()
        .map_err(|error| format!("cannot start managed Cargo '{}': {error}", cargo.display()))?;
    if !status.success() {
        return Err(format!(
            "native module compilation failed with exit code {}",
            status.code().unwrap_or(1)
        ));
    }
    regular_directory(target, "native module Cargo target after build")?;
    regular_directory(&release_directory, "native module Cargo release output")?;
    Ok(candidate)
}

fn remove_stale_candidate(path: &Path) -> Result<(), String> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_file() && !crate::filesystem::is_reparse(&metadata) => {
            fs::remove_file(path).map_err(|error| {
                format!(
                    "cannot remove stale native command candidate '{}': {error}",
                    path.display()
                )
            })
        }
        Ok(_) => Err(format!(
            "stale native command candidate is unsafe: {}",
            path.display()
        )),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!(
            "cannot inspect stale native command candidate '{}': {error}",
            path.display()
        )),
    }
}

fn validate_description(executable: &Path, domain: &NativeDomain) -> Result<(), String> {
    let mut command = Command::new(executable);
    command.arg(DESCRIPTION_ARGUMENT);
    let output = run_bounded(
        command,
        &format!("compiled command description '{}'", executable.display()),
        MAX_DESCRIPTION_BYTES,
        DESCRIPTION_TIMEOUT,
    )?;
    if !output.status.success() {
        return Err(format!(
            "compiled command description failed with exit code {}: {}",
            output.status.code().unwrap_or(1),
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    if output.stdout.len() > MAX_DESCRIPTION_BYTES || output.stderr.len() > MAX_DESCRIPTION_BYTES {
        return Err(format!(
            "compiled command description exceeds {MAX_DESCRIPTION_BYTES} bytes per stream"
        ));
    }
    if !output.stderr.is_empty() {
        return Err("compiled command description wrote to stderr".to_owned());
    }
    let description: Description = serde_json::from_slice(&output.stdout)
        .map_err(|error| format!("compiled command returned an invalid description: {error}"))?;
    let mut commands = description.commands;
    commands.sort();
    if description.schema != DESCRIPTION_SCHEMA
        || description.owner != domain.owner_address
        || commands.windows(2).any(|pair| pair[0] >= pair[1])
        || commands != domain.commands()
    {
        return Err(format!(
            "compiled command description does not match owner '{}' execution contract",
            domain.owner_address
        ));
    }
    Ok(())
}

#[derive(Debug)]
struct BoundedOutput {
    status: std::process::ExitStatus,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
}

fn run_bounded(
    mut command: Command,
    label: &str,
    maximum: usize,
    timeout: Duration,
) -> Result<BoundedOutput, String> {
    let started = Instant::now();
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("cannot run {label}: {error}"))?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| format!("cannot capture {label} stdout"))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| format!("cannot capture {label} stderr"))?;
    let stdout_reader = spawn_reader(stdout, maximum, "stdout").map_err(|error| {
        let _ = child.kill();
        let _ = child.wait();
        error
    })?;
    let stderr_reader = spawn_reader(stderr, maximum, "stderr").map_err(|error| {
        let _ = child.kill();
        let _ = child.wait();
        error
    })?;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if started.elapsed() < timeout => {
                thread::sleep(Duration::from_millis(10));
            }
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("{label} exceeded the {timeout:?} timeout"));
            }
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("cannot wait for {label}: {error}"));
            }
        }
    };
    let stdout = receive_reader(&stdout_reader, started, timeout, label, "stdout")?;
    let stderr = receive_reader(&stderr_reader, started, timeout, label, "stderr")?;
    Ok(BoundedOutput {
        status,
        stdout,
        stderr,
    })
}

fn read_bounded(mut reader: impl Read, maximum: usize) -> Result<Vec<u8>, String> {
    let mut bytes = Vec::with_capacity(maximum.saturating_add(1));
    let mut buffer = [0_u8; 8192];
    while bytes.len() <= maximum {
        let remaining = maximum + 1 - bytes.len();
        let read_limit = remaining.min(buffer.len());
        let read = reader
            .read(&mut buffer[..read_limit])
            .map_err(|error| format!("cannot read compiled command description: {error}"))?;
        if read == 0 {
            break;
        }
        bytes.extend_from_slice(&buffer[..read]);
    }
    Ok(bytes)
}

fn spawn_reader(
    reader: impl Read + Send + 'static,
    maximum: usize,
    stream: &str,
) -> Result<Receiver<Result<Vec<u8>, String>>, String> {
    let (sender, receiver) = mpsc::channel();
    thread::Builder::new()
        .name(format!("module-description-{stream}"))
        .spawn(move || {
            let _ = sender.send(read_bounded(reader, maximum));
        })
        .map_err(|error| format!("cannot start {stream} reader: {error}"))?;
    Ok(receiver)
}

fn receive_reader(
    receiver: &Receiver<Result<Vec<u8>, String>>,
    started: Instant,
    timeout: Duration,
    label: &str,
    stream: &str,
) -> Result<Vec<u8>, String> {
    let remaining = timeout.saturating_sub(started.elapsed());
    match receiver.recv_timeout(remaining) {
        Ok(result) => result,
        Err(RecvTimeoutError::Timeout) => Err(format!(
            "{label} {stream} remained open beyond the {timeout:?} timeout"
        )),
        Err(RecvTimeoutError::Disconnected) => Err(format!("{label} {stream} reader disconnected")),
    }
}

#[derive(Deserialize)]
#[serde(crate = "serde", deny_unknown_fields)]
struct Description {
    schema: String,
    owner: String,
    commands: Vec<String>,
}

#[cfg(test)]
mod tests {
    use super::{read_bounded, remove_stale_candidate, run_bounded};
    use crate::filesystem::unique_token;
    use std::fs;
    use std::process::Command;
    use std::time::{Duration, Instant};

    const HELPER_MODE: &str = "SWAWKIT_MODULE_DESCRIPTION_TEST_MODE";

    #[test]
    fn description_reader_stops_at_one_byte_over_the_limit() {
        let bytes = vec![b'x'; 32];
        assert_eq!(read_bounded(bytes.as_slice(), 8).unwrap().len(), 9);
    }

    #[test]
    fn stale_candidate_is_removed_before_cargo_runs() {
        let root = std::env::temp_dir().join(format!("swawkit-stale-candidate-{}", unique_token()));
        fs::create_dir(&root).unwrap();
        let candidate = root.join("run.exe");
        fs::write(&candidate, b"stale").unwrap();
        remove_stale_candidate(&candidate).unwrap();
        assert!(fs::symlink_metadata(&candidate).is_err());
        let _ = fs::remove_dir(&root);
    }

    #[test]
    fn descendant_holding_stdout_cannot_bypass_the_deadline() {
        let executable = std::env::current_exe().unwrap();
        let mut command = Command::new(executable);
        command
            .args([
                "--ignored",
                "--exact",
                "instantiate::tests::description_pipe_holder_helper",
                "--nocapture",
                "--test-threads=1",
            ])
            .env(HELPER_MODE, "parent");
        let started = Instant::now();
        let error = run_bounded(
            command,
            "description fixture",
            64 * 1024,
            Duration::from_millis(500),
        )
        .unwrap_err();
        assert!(error.contains("timeout"), "{error}");
        assert!(started.elapsed() < Duration::from_millis(1200));
    }

    #[test]
    #[ignore]
    fn description_pipe_holder_helper() {
        match std::env::var(HELPER_MODE).as_deref() {
            Ok("parent") => {
                let executable = std::env::current_exe().unwrap();
                Command::new(executable)
                    .args([
                        "--ignored",
                        "--exact",
                        "instantiate::tests::description_pipe_holder_helper",
                        "--nocapture",
                        "--test-threads=1",
                    ])
                    .env(HELPER_MODE, "descendant")
                    .spawn()
                    .unwrap();
            }
            Ok("descendant") => std::thread::sleep(Duration::from_millis(1500)),
            _ => {}
        }
    }
}
