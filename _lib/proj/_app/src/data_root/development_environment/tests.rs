use super::*;
use std::os::windows::process::CommandExt;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    root: PathBuf,
    data_root: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "swawkit-dev-repair-{}-{sequence}",
            std::process::id()
        ));
        let data_root = root.join("data/proj.fixture");
        fs::create_dir_all(&data_root).expect("create fixture DataRoot");
        Self { root, data_root }
    }

    fn environment_root(&self) -> PathBuf {
        self.data_root.join("dev_env")
    }

    fn write_publication(&self, name: &str, content: &str) {
        fs::create_dir_all(self.environment_root()).expect("create environment root");
        fs::write(self.environment_root().join(name), content).expect("write publication");
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let environment_root = self.environment_root();
        if fs::symlink_metadata(&environment_root)
            .is_ok_and(|metadata| metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0)
        {
            let _ = fs::remove_dir(&environment_root);
        }
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn keeps_a_current_partial_publication_and_removes_state_only_residue() {
    let fixture = Fixture::new();
    let environment_root = fixture.environment_root();
    fixture.write_publication(
        "env.cmd",
        &format!(
            "rem {GENERATED_MARKER}\r\nset \"SWAWKIT_PROJ_DEV_ENV_ROOT={}\"\r\n",
            environment_root.display()
        ),
    );
    assert_eq!(
        repair_development_environment(&fixture.data_root).expect("repair current"),
        DevelopmentEnvironmentRepair::Current
    );
    assert!(environment_root.join("env.cmd").is_file());

    fs::remove_file(environment_root.join("env.cmd")).expect("remove publication");
    fs::write(environment_root.join("_state.json"), "{}").expect("write state");
    assert_eq!(
        repair_development_environment(&fixture.data_root).expect("repair state"),
        DevelopmentEnvironmentRepair::NoPublication
    );
    assert!(!environment_root.join("_state.json").exists());
}

#[test]
fn removes_generated_publications_that_reference_the_old_data_root() {
    let fixture = Fixture::new();
    let environment_root = fixture.environment_root();
    fixture.write_publication(
        "env.cmd",
        &format!(
            "rem {GENERATED_MARKER}\r\nset \"SWAWKIT_PROJ_DEV_ENV_ROOT={}\"\r\n",
            fixture.root.join("old/dev_env").display()
        ),
    );
    fixture.write_publication(
        "env.ps1",
        &format!(
            "# {GENERATED_MARKER}\r\n$env:SWAWKIT_PROJ_DEV_ENV_ROOT = '{}'\r\n",
            fixture.root.join("old/dev_env").display()
        ),
    );
    fs::write(environment_root.join("_state.json"), "{}").expect("write state");

    assert_eq!(
        repair_development_environment(&fixture.data_root).expect("repair stale"),
        DevelopmentEnvironmentRepair::RemovedStale
    );
    for name in ["env.cmd", "env.ps1", "_state.json"] {
        assert!(!environment_root.join(name).exists());
    }
}

#[test]
fn refuses_to_delete_an_unrecognized_file() {
    let fixture = Fixture::new();
    fixture.write_publication(
        "env.cmd",
        "set \"SWAWKIT_PROJ_DEV_ENV_ROOT=D:\\somewhere\"\r\n",
    );
    let error = repair_development_environment(&fixture.data_root).unwrap_err();
    assert!(error.to_string().contains("not recognized as generated"));
    assert!(fixture.environment_root().join("env.cmd").is_file());
}

#[test]
fn refuses_to_follow_a_managed_environment_junction() {
    let fixture = Fixture::new();
    let external = fixture.root.join("external");
    fs::create_dir(&external).expect("create external directory");
    fs::write(external.join("sentinel.txt"), "preserve").expect("write sentinel");
    create_junction(&fixture.environment_root(), &external);

    let error = repair_development_environment(&fixture.data_root).unwrap_err();
    assert!(error.to_string().contains("cannot be a reparse point"));
    assert!(external.join("sentinel.txt").is_file());
}

fn create_junction(link: &Path, target: &Path) {
    let command = format!(
        "mklink /J \"{}\" \"{}\"",
        link.display(),
        target.display()
    );
    let mut process = Command::new("cmd.exe");
    process.args(["/d", "/c"]);
    process.raw_arg(&command);
    let output = process
        .output()
        .expect("run mklink");
    assert!(
        output.status.success(),
        "create junction: {} {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}
