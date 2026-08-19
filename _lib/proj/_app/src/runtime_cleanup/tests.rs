use super::*;
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use crate::runtime_release::tests::write_release;

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    root: PathBuf,
    context: EntryContext,
}

impl Fixture {
    fn new() -> Self {
        let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "swawkit-runtime-cleanup-launch-{}-{sequence}",
            std::process::id()
        ));
        let releases = root.join("_lib/proj/_bin/releases");
        let artifacts = [
            ("swawkit-proj.exe", b"core".as_slice()),
            ("swawkit-proj-host.exe", b"host".as_slice()),
            ("swawkit-proj-module.exe", b"module".as_slice()),
            ("swawkit-proj-dev.exe", b"dev".as_slice()),
        ];
        let release_id = write_release(&releases, &artifacts);
        fs::write(
            root.join("_lib/proj/_bin/current"),
            format!("{release_id}\n"),
        )
        .unwrap();
        fs::create_dir_all(root.join("data")).unwrap();
        let context = EntryContext {
            swawkit_home: root.clone(),
            entry_file: root.join("swawkit.exe"),
            entry_name: "swawkit".to_owned(),
            invocation_directory: root.clone(),
            product_executable: releases.join(&release_id).join("swawkit-proj.exe"),
            release_id,
        };
        Self { root, context }
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn cleanup_json_runs_in_process_without_a_runtime_sibling_product() {
    let fixture = Fixture::new();
    let document = execute_json(&fixture.context, false).expect("preview Runtime cleanup");
    assert_eq!(document.protocol, RUNTIME_CLEANUP_PROTOCOL);
    assert_eq!(document.action, RuntimeCleanupAction::Preview);
}
