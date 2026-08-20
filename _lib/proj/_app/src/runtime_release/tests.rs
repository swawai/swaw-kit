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
        let data_root = root.join("data/proj.entry");
        let runtime_root = data_root.join("runtime");
        fs::create_dir_all(runtime_root.join("releases")).expect("create Runtime root");
        let running = "a".repeat(64);
        let selected = "b".repeat(64);
        fs::write(runtime_root.join("current"), format!("{selected}\n")).expect("write selector");
        Self {
            context: EntryContext {
                swawkit_home: root.clone(),
                data_root,
                runtime_root: runtime_root.clone(),
                entry_file: root.join("entry.exe"),
                entry_name: "entry".to_owned(),
                entry_id: crate::entry::EntryId::parse(&"a".repeat(64)).unwrap(),
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
fn per_entry_runtime_fixture_does_not_create_the_legacy_shared_bin_layout() {
    let fixture = Fixture::new();
    assert!(!fixture.root.join("_lib/proj/_bin").exists());
}

#[test]
fn rejects_noncanonical_selector_content() {
    let fixture = Fixture::new();
    fs::write(
        fixture.context.runtime_root.join("current"),
        format!("{}\r\n", "B".repeat(64)),
    )
    .expect("replace selector");
    assert!(selected_release_id(&fixture.context).is_err());
}

#[test]
fn bounded_reader_rejects_a_file_that_grows_after_initial_metadata() {
    let fixture = Fixture::new();
    let selector = fixture.context.runtime_root.join("current");
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
    let releases = fixture.context.runtime_root.join("releases");
    let release_id = write_release(&fixture.root, &releases, &artifacts);

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

    let releases = fixture.context.runtime_root.join("releases");
    let forward_id = write_release(&fixture.root, &releases, &forward);
    fs::remove_dir_all(releases.join(&forward_id)).unwrap();
    let reverse_id = write_release(&fixture.root, &releases, &reverse);

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
    let releases = fixture.context.runtime_root.join("releases");
    let release_id = write_release(&fixture.root, &releases, &artifacts);
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
        .context
        .runtime_root
        .join("releases")
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
    let releases = fixture.context.runtime_root.join("releases");
    let release_id = write_release(&fixture.root, &releases, &artifacts);
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
        .context
        .runtime_root
        .join("releases")
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

#[test]
fn clones_an_explicit_release_without_linking_source_bytes() {
    let fixture = Fixture::new();
    let releases = fixture.context.runtime_root.join("releases");
    let selected_id = write_release(
        &fixture.root,
        &releases,
        &[
            ("swawkit-proj.exe", b"selected-core"),
            ("swawkit-proj-host.exe", b"selected-host"),
            ("swawkit-proj-module.exe", b"selected-module"),
            ("swawkit-proj-dev.exe", b"selected-dev"),
        ],
    );
    let explicit_id = write_release(
        &fixture.root,
        &releases,
        &[
            ("swawkit-proj.exe", b"explicit-core"),
            ("swawkit-proj-host.exe", b"explicit-host"),
            ("swawkit-proj-module.exe", b"explicit-module"),
            ("swawkit-proj-dev.exe", b"explicit-dev"),
        ],
    );
    fs::write(
        fixture.context.runtime_root.join("current"),
        format!("{selected_id}\n"),
    )
    .unwrap();
    let source = RuntimeReleaseStore::open(&fixture.context.runtime_root, &fixture.root).unwrap();
    let target_root = fixture.root.join("data/proj.target/runtime");
    fs::create_dir_all(target_root.parent().unwrap()).unwrap();
    let target = RuntimeReleaseStore::initialize(&target_root, &fixture.root).unwrap();

    target
        .publish_clone_from(&source, &explicit_id)
        .expect("clone explicit non-selected Release");
    target.select(&explicit_id).expect("select cloned Release");
    assert_eq!(target.selected_release_id().unwrap(), explicit_id);
    target.validate(&explicit_id).unwrap();
    assert!(!target.releases_root().join(&selected_id).exists());

    fs::write(
        releases.join(&explicit_id).join("swawkit-proj.exe"),
        b"source changed after clone",
    )
    .unwrap();
    target
        .validate(&explicit_id)
        .expect("target bytes are physically independent");
}

#[test]
fn clone_is_idempotent_but_never_repairs_an_invalid_same_id_target() {
    let fixture = Fixture::new();
    let source_releases = fixture.context.runtime_root.join("releases");
    let release_id = write_release(
        &fixture.root,
        &source_releases,
        &[
            ("swawkit-proj.exe", b"core"),
            ("swawkit-proj-host.exe", b"host"),
            ("swawkit-proj-module.exe", b"module"),
            ("swawkit-proj-dev.exe", b"dev"),
        ],
    );
    let source = RuntimeReleaseStore::open(&fixture.context.runtime_root, &fixture.root).unwrap();
    let valid_root = fixture.root.join("data/proj.valid/runtime");
    fs::create_dir_all(valid_root.parent().unwrap()).unwrap();
    let valid = RuntimeReleaseStore::initialize(&valid_root, &fixture.root).unwrap();
    valid.publish_clone_from(&source, &release_id).unwrap();
    valid.publish_clone_from(&source, &release_id).unwrap();

    let invalid_root = fixture.root.join("data/proj.invalid/runtime");
    fs::create_dir_all(invalid_root.parent().unwrap()).unwrap();
    let invalid = RuntimeReleaseStore::initialize(&invalid_root, &fixture.root).unwrap();
    let collision = invalid.releases_root().join(&release_id);
    fs::create_dir(&collision).unwrap();
    fs::write(collision.join("foreign"), b"preserve me").unwrap();
    assert!(invalid.publish_clone_from(&source, &release_id).is_err());
    assert_eq!(fs::read(collision.join("foreign")).unwrap(), b"preserve me");
}

#[test]
fn selecting_an_invalid_release_preserves_the_complete_old_selector() {
    let fixture = Fixture::new();
    let releases = fixture.context.runtime_root.join("releases");
    let valid_id = write_release(
        &fixture.root,
        &releases,
        &[
            ("swawkit-proj.exe", b"core"),
            ("swawkit-proj-host.exe", b"host"),
            ("swawkit-proj-module.exe", b"module"),
            ("swawkit-proj-dev.exe", b"dev"),
        ],
    );
    fs::write(
        fixture.context.runtime_root.join("current"),
        format!("{valid_id}\n"),
    )
    .unwrap();
    let store = RuntimeReleaseStore::open(&fixture.context.runtime_root, &fixture.root).unwrap();

    assert!(store.select(&"f".repeat(64)).is_err());
    assert_eq!(store.selected_release_id().unwrap(), valid_id);
}

pub(crate) fn write_release(
    swawkit_home: &Path,
    root: &Path,
    artifacts: &[(&str, &[u8])],
) -> String {
    let command_runtime_id = write_command_runtime(swawkit_home);
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
