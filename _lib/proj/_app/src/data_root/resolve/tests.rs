use super::*;
use crate::data_root::claim::ClaimKind;
use crate::data_root::lock::DataRootLock;
use crate::data_root::record::{publish_entry_record, read_entry_record};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    root: PathBuf,
    proj_home: PathBuf,
    project_root: PathBuf,
    action_root: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "swawkit-data-resolve-{}-{sequence}",
            std::process::id()
        ));
        let proj_home = root.join("home");
        let project_root = root.join("project");
        let action_root = project_root.join(".swaw");
        fs::create_dir_all(&proj_home).expect("create Proj home");
        fs::create_dir_all(&project_root).expect("create project root");
        Self {
            root,
            proj_home,
            project_root,
            action_root,
        }
    }

    fn entry(&self, name: &str) -> PathBuf {
        self.project_root.join(format!("{name}.cmd"))
    }

    fn write_entry(&self, name: &str, content: &str) -> PathBuf {
        let path = self.entry(name);
        fs::write(&path, content).expect("write entry");
        path
    }

    fn data_root(&self, name: &str) -> PathBuf {
        self.proj_home.join("data").join(format!("proj.{name}"))
    }

    fn request<'a>(&'a self, entry_file: &'a Path) -> ResolveDataRootRequest<'a> {
        ResolveDataRootRequest {
            proj_home: &self.proj_home,
            project_root: &self.project_root,
            action_root: &self.action_root,
            entry_file,
            inherited_data_root: None,
        }
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn approve(_claim: &DataRootClaim) -> Result<bool, ClaimApprovalError> {
    Ok(true)
}

#[test]
fn creates_and_then_directly_reuses_a_bound_data_root() {
    let fixture = Fixture::new();
    let entry = fixture.write_entry("alpha", "first");
    let mut unexpected_claim = |_claim: &DataRootClaim| {
        Err(ClaimApprovalError::new("claim was not expected"))
    };

    let first = resolve_data_root(fixture.request(&entry), &mut unexpected_claim)
        .expect("create DataRoot");
    assert_eq!(first.path, fixture.data_root("alpha"));
    assert_eq!(
        first.development_environment_repair,
        DevelopmentEnvironmentRepair::NoPublication
    );
    assert!(first.path.join("_entry.json").is_file());
    assert!(fixture.proj_home.join("data/_proj-entry.lock").is_file());

    let second = resolve_data_root(fixture.request(&entry), &mut unexpected_claim)
        .expect("direct DataRoot");
    assert_eq!(second.path, first.path);
}

#[test]
fn claim_current_replaces_an_invalid_record_only_after_approval() {
    let fixture = Fixture::new();
    let entry = fixture.write_entry("beta", "entry");
    let data_root = fixture.data_root("beta");
    fs::create_dir_all(&data_root).expect("create unbound DataRoot");
    fs::write(data_root.join("_entry.json"), "invalid").expect("write invalid record");
    let mut saw_claim = false;
    let mut approver = |claim: &DataRootClaim| {
        saw_claim = claim.kind == ClaimKind::Current
            && claim.data_root == data_root
            && claim.source_data_root.is_none();
        Ok(true)
    };

    let resolved = resolve_data_root(fixture.request(&entry), &mut approver)
        .expect("claim current DataRoot");
    assert!(saw_claim);
    assert_eq!(resolved.path, data_root);
    assert!(read_entry_record(&data_root).valid_record().is_some());
    assert!(
        fs::read_dir(&data_root)
            .expect("read DataRoot")
            .all(|entry| !entry.expect("entry").file_name().to_string_lossy().contains("._entry"))
    );
}

#[test]
fn denial_leaves_an_unbound_data_root_unchanged() {
    let fixture = Fixture::new();
    let entry = fixture.write_entry("gamma", "entry");
    let data_root = fixture.data_root("gamma");
    fs::create_dir_all(&data_root).expect("create unbound DataRoot");
    let mut deny = |_claim: &DataRootClaim| Ok(false);

    let error = resolve_data_root(fixture.request(&entry), &mut deny).unwrap_err();
    assert!(error.is_approval_denied());
    assert!(!data_root.join("_entry.json").exists());
}

#[test]
fn accepts_when_another_process_completes_the_same_claim_during_confirmation() {
    let fixture = Fixture::new();
    let entry = fixture.write_entry("completed", "entry");
    let data_root = fixture.data_root("completed");
    fs::create_dir_all(&data_root).expect("create unbound DataRoot");
    let data_directory = fixture.proj_home.join("data");
    let mut approver = |claim: &DataRootClaim| {
        let lock = DataRootLock::acquire_for_test(&data_directory, 1, Duration::ZERO)
            .expect("simulate the completing process");
        let identity = EntryIdentity::from_parts(&claim.volume_id, &claim.file_id)
            .expect("claim identity");
        publish_entry_record(
            &claim.data_root,
            &claim.entry_name,
            &claim.entry_file,
            &identity,
        )
        .expect("complete binding");
        drop(lock);
        Ok(true)
    };

    let resolved = resolve_data_root(fixture.request(&entry), &mut approver)
        .expect("accept completed claim");
    assert_eq!(resolved.path, data_root);
    assert!(read_entry_record(&data_root).valid_record().is_some());
}

#[test]
fn rename_follows_file_identity_and_invalidates_moved_dev_environment() {
    let fixture = Fixture::new();
    let old_entry = fixture.write_entry("old-name", "entry");
    let mut approver = approve;
    let old = resolve_data_root(fixture.request(&old_entry), &mut approver)
        .expect("create old binding");
    let environment_root = old.path.join("dev_env");
    fs::create_dir(&environment_root).expect("create dev environment");
    fs::write(
        environment_root.join("env.cmd"),
        format!(
            "rem Generated by Swaw Kit Proj.\r\nset \"SWAWKIT_DEV_ENV_ROOT={}\"\r\n",
            environment_root.display()
        ),
    )
    .expect("write old environment");
    fs::write(environment_root.join("_state.json"), "{}").expect("write old state");

    let new_entry = fixture.entry("new-name");
    fs::rename(&old_entry, &new_entry).expect("rename entry");
    let mut saw_rename = false;
    let mut rename_approver = |claim: &DataRootClaim| {
        saw_rename = claim.kind == ClaimKind::Rename
            && claim.source_data_root.as_deref() == Some(old.path.as_path());
        Ok(true)
    };
    let renamed = resolve_data_root(fixture.request(&new_entry), &mut rename_approver)
        .expect("claim renamed DataRoot");

    assert!(saw_rename);
    assert_eq!(renamed.path, fixture.data_root("new-name"));
    assert!(!old.path.exists());
    assert_eq!(
        renamed.development_environment_repair,
        DevelopmentEnvironmentRepair::RemovedStale
    );
    assert_eq!(renamed.warnings.len(), 1);
    assert!(!renamed.path.join("dev_env/env.cmd").exists());
    assert!(!renamed.path.join("dev_env/_state.json").exists());
}

#[test]
fn confirmation_holds_no_lock_and_rejects_a_changed_entry_identity() {
    let fixture = Fixture::new();
    let entry = fixture.write_entry("epsilon", "original");
    let mut approver = approve;
    let original = resolve_data_root(fixture.request(&entry), &mut approver)
        .expect("create original binding");
    replace_entry(&entry, "first replacement");

    let data_directory = fixture.proj_home.join("data");
    let mut checking_approver = |_claim: &DataRootClaim| {
        let lock = DataRootLock::acquire_for_test(&data_directory, 1, Duration::ZERO)
            .expect("confirmation must not hold the DataRoot lock");
        drop(lock);
        replace_entry(&entry, "second replacement");
        Ok(true)
    };
    let error = resolve_data_root(fixture.request(&entry), &mut checking_approver)
        .unwrap_err();
    assert!(error.is_state_changed());
    let published = read_entry_record(&original.path);
    let record = published.valid_record().expect("original record remains");
    assert_ne!(record.file_id, EntryIdentity::read(&entry).expect("new identity").file_id());
}

#[test]
fn migrates_a_matching_legacy_root_without_claim_and_cleans_its_directory() {
    let fixture = Fixture::new();
    let entry = fixture.write_entry("legacy", "entry");
    let identity = EntryIdentity::read(&entry).expect("entry identity");
    let legacy_directory = fixture.project_root.join("data");
    let legacy_root = legacy_directory.join("proj.legacy");
    fs::create_dir_all(&legacy_root).expect("create legacy root");
    publish_entry_record(&legacy_root, "legacy", &entry, &identity)
        .expect("publish legacy record");
    fs::write(legacy_directory.join("_proj-entry.lock"), "").expect("write stale lock file");
    let mut unexpected_claim = |_claim: &DataRootClaim| {
        Err(ClaimApprovalError::new("legacy migration should not claim"))
    };

    let resolved = resolve_data_root(fixture.request(&entry), &mut unexpected_claim)
        .expect("migrate legacy root");
    assert_eq!(resolved.path, fixture.data_root("legacy"));
    assert!(!legacy_root.exists());
    assert!(!legacy_directory.exists());
}

fn replace_entry(path: &Path, content: &str) {
    let replacement = path.with_extension(format!(
        "{}.replacement",
        NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed)
    ));
    fs::write(&replacement, content).expect("write replacement");
    fs::remove_file(path).expect("remove previous entry");
    fs::rename(replacement, path).expect("publish replacement entry");
}
