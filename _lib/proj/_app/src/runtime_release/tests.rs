use super::*;
use std::io::Write;
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    root: PathBuf,
    context: EntryContext,
}

impl Fixture {
    fn new() -> Self {
        let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "swawkit-runtime-release-{}-{sequence}",
            std::process::id()
        ));
        let runtime_root = root.join("_lib/proj/_bin");
        fs::create_dir_all(runtime_root.join("releases")).expect("create Runtime root");
        let running = "a".repeat(64);
        let selected = "b".repeat(64);
        fs::write(runtime_root.join("current"), format!("{selected}\n")).expect("write selector");
        Self {
            context: EntryContext {
                swawkit_home: root.clone(),
                entry_file: root.join("entry.exe"),
                entry_name: "entry".to_owned(),
                invocation_directory: root.clone(),
                product_executable: runtime_root
                    .join("releases")
                    .join(&running)
                    .join("swawkit-proj-host.exe"),
                release_id: running,
            },
            root,
        }
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn reads_the_selected_release_independently_of_the_running_release() {
    let fixture = Fixture::new();
    assert_eq!(
        selected_release_id(&fixture.context).unwrap(),
        "b".repeat(64)
    );
    assert_eq!(fixture.context.release_id, "a".repeat(64));
}

#[test]
fn rejects_noncanonical_selector_content() {
    let fixture = Fixture::new();
    fs::write(
        fixture.context.command_root().join("_bin/current"),
        format!("{}\r\n", "B".repeat(64)),
    )
    .expect("replace selector");
    assert!(selected_release_id(&fixture.context).is_err());
}

#[test]
fn bounded_reader_rejects_a_file_that_grows_after_initial_metadata() {
    let fixture = Fixture::new();
    let selector = fixture.context.command_root().join("_bin/current");
    let mut file = open_regular_file(&selector, "Runtime selector", SELECTOR_BYTES)
        .expect("open selector through its guarded handle");
    let initial_length = file.metadata().expect("selector metadata").len();
    fs::OpenOptions::new()
        .append(true)
        .open(&selector)
        .expect("open concurrent selector writer")
        .write_all(b"x")
        .expect("grow selector after initial metadata");

    let error = read_bounded_contents(
        &mut file,
        &selector,
        "Runtime selector",
        SELECTOR_BYTES,
        initial_length,
    )
    .expect_err("concurrent growth must fail closed");
    assert!(
        error.to_string().contains("exceeds its size limit"),
        "{error}"
    );
}

#[test]
fn accepts_an_exact_four_member_v4_release() {
    let fixture = Fixture::new();
    let artifacts = [
        ("swawkit-proj.exe", b"core".as_slice()),
        ("swawkit-proj-host.exe", b"host".as_slice()),
        ("swawkit-proj-module.exe", b"module".as_slice()),
        ("swawkit-proj-dev.exe", b"dev".as_slice()),
    ];
    let releases = fixture.root.join("_lib/proj/_bin/releases");
    let release_id = write_release(&releases, &artifacts);

    validate_release(&releases.join(&release_id), &release_id, &fixture.root)
        .expect("validate exact Runtime Release membership");
}

#[test]
fn release_identity_is_canonical_by_artifact_name() {
    let fixture = Fixture::new();
    let forward = [
        ("swawkit-proj.exe", b"core".as_slice()),
        ("swawkit-proj-dev.exe", b"dev".as_slice()),
        ("swawkit-proj-host.exe", b"host".as_slice()),
        ("swawkit-proj-module.exe", b"module".as_slice()),
    ];
    let reverse = [
        ("swawkit-proj-module.exe", b"module".as_slice()),
        ("swawkit-proj-host.exe", b"host".as_slice()),
        ("swawkit-proj-dev.exe", b"dev".as_slice()),
        ("swawkit-proj.exe", b"core".as_slice()),
    ];

    let releases = fixture.root.join("_lib/proj/_bin/releases");
    let forward_id = write_release(&releases, &forward);
    fs::remove_dir_all(releases.join(&forward_id)).unwrap();
    let reverse_id = write_release(&releases, &reverse);

    assert_eq!(forward_id, reverse_id);
    validate_release(&releases.join(&reverse_id), &reverse_id, &fixture.root)
        .expect("validate a manifest whose records are not in identity order");
}

#[test]
fn running_release_structure_does_not_follow_the_current_selector() {
    let fixture = Fixture::new();
    let artifacts = [
        ("swawkit-proj.exe", b"core".as_slice()),
        ("swawkit-proj-host.exe", b"host".as_slice()),
        ("swawkit-proj-module.exe", b"module".as_slice()),
        ("swawkit-proj-dev.exe", b"dev".as_slice()),
    ];
    let releases = fixture.root.join("_lib/proj/_bin/releases");
    let release_id = write_release(&releases, &artifacts);
    let context = EntryContext {
        product_executable: releases.join(&release_id).join("swawkit-proj-host.exe"),
        release_id,
        ..fixture.context.clone()
    };

    validate_running_release(&context).expect("validate the running Release directly");
}

#[test]
fn running_release_rejects_legacy_or_incomplete_membership() {
    let fixture = Fixture::new();
    let release = fixture
        .root
        .join("_lib/proj/_bin/releases")
        .join(&fixture.context.release_id);
    fs::create_dir_all(&release).unwrap();
    fs::write(release.join("swawkit-proj-host.exe"), b"host").unwrap();
    fs::write(
        release.join("manifest.json"),
        br#"{"schema":"swawkit.proj-release-set/v2","releaseId":"invalid","artifacts":[]}"#,
    )
    .unwrap();

    assert!(validate_running_release(&fixture.context).is_err());
}

#[test]
fn validates_only_the_runtime_product_that_will_be_started() {
    let fixture = Fixture::new();
    let artifacts = [
        ("swawkit-proj.exe", b"core".as_slice()),
        ("swawkit-proj-host.exe", b"host".as_slice()),
        ("swawkit-proj-module.exe", b"module".as_slice()),
        ("swawkit-proj-dev.exe", b"dev".as_slice()),
    ];
    let releases = fixture.root.join("_lib/proj/_bin/releases");
    let release_id = write_release(&releases, &artifacts);
    let host = releases.join(&release_id).join("swawkit-proj-host.exe");
    validate_product(&host).expect("validate selected product artifact");

    fs::write(&host, b"h0st").unwrap();
    assert!(validate_product(&host).is_err());
}

#[test]
fn rejects_a_v4_release_without_the_module_artifact() {
    let fixture = Fixture::new();
    let release_id = "c".repeat(64);
    let release = fixture
        .root
        .join("_lib/proj/_bin/releases")
        .join(&release_id);
    fs::create_dir_all(&release).expect("create incomplete Runtime Release");
    let artifacts = [
        ("swawkit-proj.exe", b"core".as_slice()),
        ("swawkit-proj-host.exe", b"host".as_slice()),
        ("swawkit-proj-dev.exe", b"dev".as_slice()),
    ];
    let records = artifacts
        .iter()
        .map(|(name, bytes)| {
            fs::write(release.join(name), bytes).expect("write incomplete artifact");
            serde_json::json!({
                "name": name,
                "length": bytes.len(),
                "sha256": format!("{:x}", Sha256::digest(bytes)),
            })
        })
        .collect::<Vec<_>>();
    fs::write(
        release.join("manifest.json"),
        serde_json::to_vec(&serde_json::json!({
            "schema": RUNTIME_RELEASE_SCHEMA,
            "releaseId": release_id,
            "commandRuntimeId": "d".repeat(64),
            "artifacts": records,
        }))
        .expect("serialize incomplete manifest"),
    )
    .expect("write incomplete manifest");

    assert!(validate_release(&release, &release_id, &fixture.root).is_err());
}

pub(crate) fn write_release(root: &Path, artifacts: &[(&str, &[u8])]) -> String {
    let command_runtime_id = infer_swawkit_home(root)
        .map(|home| write_command_runtime(&home))
        .unwrap_or_else(|| "d".repeat(64));
    let records = artifacts
        .iter()
        .map(|(name, bytes)| {
            let sha256 = format!("{:x}", Sha256::digest(bytes));
            (
                serde_json::json!({
                    "name": name,
                    "length": bytes.len(),
                    "sha256": sha256,
                }),
                [(*name).to_owned(), bytes.len().to_string(), sha256],
            )
        })
        .collect::<Vec<_>>();
    let mut identity = vec![
        RUNTIME_RELEASE_SCHEMA.to_owned(),
        command_runtime_id.clone(),
    ];
    let mut identity_records = records.iter().collect::<Vec<_>>();
    identity_records.sort_by(|left, right| left.1[0].cmp(&right.1[0]));
    for (_, fields) in identity_records {
        identity.extend(fields.iter().cloned());
    }
    let release_id = format!("{:x}", Sha256::digest(identity.join("\n").as_bytes()));
    let release = root.join(&release_id);
    fs::create_dir_all(&release).expect("create Runtime Release");
    for ((name, bytes), _) in artifacts.iter().zip(&records) {
        fs::write(release.join(name), bytes).expect("write Runtime artifact");
    }
    fs::write(
        release.join("manifest.json"),
        serde_json::to_vec(&serde_json::json!({
            "schema": RUNTIME_RELEASE_SCHEMA,
            "releaseId": release_id,
            "commandRuntimeId": command_runtime_id,
            "artifacts": records.into_iter().map(|(record, _)| record).collect::<Vec<_>>(),
        }))
        .expect("serialize Runtime manifest"),
    )
    .expect("write Runtime manifest");
    release_id
}

fn infer_swawkit_home(releases: &Path) -> Option<PathBuf> {
    (releases.file_name()? == "releases")
        .then_some(())
        .and_then(|()| releases.parent())
        .filter(|path| path.file_name().is_some_and(|name| name == "_bin"))
        .and_then(Path::parent)
        .filter(|path| path.file_name().is_some_and(|name| name == "proj"))
        .and_then(Path::parent)
        .filter(|path| path.file_name().is_some_and(|name| name == "_lib"))
        .and_then(Path::parent)
        .map(Path::to_path_buf)
}

pub(crate) fn write_command_runtime(home: &Path) -> String {
    let bootstrap = home.join("data/proj_cache/bootstrap");
    let tool_root = bootstrap.join("fixture-tools");
    fs::create_dir_all(&tool_root).expect("create Command Runtime fixture tools");
    let tools = [
        ("bun", "1.2.15", "fixture-tools/bun.exe", b"bun".as_slice()),
        (
            "pwsh",
            "7.6.4",
            "fixture-tools/pwsh.exe",
            b"pwsh".as_slice(),
        ),
    ];
    let records = tools
        .iter()
        .map(|(name, version, relative, bytes)| {
            fs::write(bootstrap.join(relative), bytes).expect("write Command Runtime tool");
            serde_json::json!({
                "name": name,
                "version": version,
                "path": relative,
                "length": bytes.len(),
                "sha256": format!("{:x}", Sha256::digest(bytes)),
            })
        })
        .collect::<Vec<_>>();
    let mut identity = vec![crate::command_runtime::COMMAND_RUNTIME_SCHEMA.to_owned()];
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
    fs::create_dir_all(&release).expect("create Command Runtime fixture release");
    fs::write(
        release.join("manifest.json"),
        serde_json::to_vec(&serde_json::json!({
            "schema": crate::command_runtime::COMMAND_RUNTIME_SCHEMA,
            "runtimeId": runtime_id,
            "tools": records,
        }))
        .expect("serialize Command Runtime fixture"),
    )
    .expect("write Command Runtime fixture");
    runtime_id
}
