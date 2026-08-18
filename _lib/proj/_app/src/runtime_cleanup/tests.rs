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
        let artifacts = [
            ("swawkit-proj.exe", b"core".as_slice()),
            ("swawkit-proj-host.exe", b"host".as_slice()),
            ("swawkit-proj-module.exe", b"module".as_slice()),
            ("swawkit-proj-toolchain.exe", b"toolchain".as_slice()),
        ];
        let release_id = write_release(&root, &artifacts);
        let context = EntryContext {
            swawkit_home: root.clone(),
            entry_file: root.join("swawkit.exe"),
            entry_name: "swawkit".to_owned(),
            invocation_directory: root.clone(),
            product_executable: root.join(&release_id).join("swawkit-proj.exe"),
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
fn cleanup_rejects_an_equal_length_tampered_toolchain_before_launch() {
    let fixture = Fixture::new();
    let toolchain = fixture
        .context
        .sibling_product_executable("swawkit-proj-toolchain.exe");
    fs::write(&toolchain, b"t00lchain").expect("tamper Toolchain without changing its length");

    let error = cleanup_command(&fixture.context, false, "json")
        .expect_err("tampered Toolchain must not reach process launch");
    assert!(error.contains("SHA-256"), "{error}");
}
