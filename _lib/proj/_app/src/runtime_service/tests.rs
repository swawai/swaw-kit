use std::fs;
use std::io;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};

use super::*;
use crate::data_root::{DataRootSession, ResolveDataRootRequest, resolve_data_root};
use crate::process_runner::{ProcessControl, ProcessObserver};
use crate::run_journal::RunJournalSource;

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

#[derive(Default)]
struct RecordingRunner {
    starts: AtomicUsize,
}

impl RecordingRunner {
    fn start_count(&self) -> usize {
        self.starts.load(Ordering::Acquire)
    }
}

impl RuntimeExecutionRunner for RecordingRunner {
    fn start(
        &self,
        _execution: PreparedExecution,
        _observer: Arc<dyn ProcessObserver>,
    ) -> io::Result<Arc<dyn ProcessControl>> {
        self.starts.fetch_add(1, Ordering::AcqRel);
        Err(io::Error::other("recording runner must not start"))
    }
}

struct Fixture {
    root: PathBuf,
    release_id: String,
}

impl Fixture {
    fn new() -> Self {
        let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "swawkit-runtime-service-{}-{sequence}",
            std::process::id()
        ));
        let data_root = root.join("home/data/proj.swawkit");
        let runtime_root = data_root.join("runtime");
        fs::create_dir_all(runtime_root.join("releases")).expect("create Runtime root");
        fs::create_dir_all(root.join("home/_lib/proj/system")).expect("create System command root");
        fs::create_dir_all(root.join("home/_lib/proj/modules")).expect("create swaw Module root");
        let release_id = crate::runtime_release::tests::write_release(
            &root.join("home"),
            &runtime_root.join("releases"),
            &[
                ("swawkit-proj.exe", b"core"),
                ("swawkit-proj-host.exe", b"host"),
                ("swawkit-proj-module.exe", b"module"),
                ("swawkit-proj-dev.exe", b"dev"),
            ],
        );
        fs::write(runtime_root.join("current"), format!("{release_id}\n"))
            .expect("write Runtime selector");
        fs::write(root.join("home/swawkit.exe"), b"fixture").expect("create fixture Entry");
        let fixture = Self { root, release_id };
        let context = fixture.context();
        resolve_data_root(ResolveDataRootRequest {
            swawkit_home: &context.swawkit_home,
            entry_file: &context.entry_file,
        })
        .expect("bind fixture DataRoot");
        fixture
    }

    fn context(&self) -> EntryContext {
        let data_root = self.root.join("home/data/proj.swawkit");
        let runtime_root = data_root.join("runtime");
        EntryContext {
            swawkit_home: self.root.join("home"),
            data_root,
            runtime_root,
            entry_file: self.root.join("home/swawkit.exe"),
            entry_name: "swawkit".to_owned(),
            invocation_directory: self.root.clone(),
            product_executable: self
                .root
                .join("home/data/proj.swawkit/runtime/releases")
                .join(&self.release_id)
                .join("swawkit-proj-host.exe"),
            release_id: self.release_id.clone(),
        }
    }

    fn data_root_session(&self) -> DataRootSession {
        let context = self.context();
        DataRootSession::new(ResolveDataRootRequest {
            swawkit_home: &context.swawkit_home,
            entry_file: &context.entry_file,
        })
        .expect("pin fixture Entry for DataRoot session")
    }

    fn install_command(&self) {
        let root = self.root.join("home/_lib/proj/system/demo");
        fs::create_dir_all(&root).expect("create fixture command");
        fs::write(
            root.join("swawkit.module.json"),
            r#"{"schema":"swawkit.command-module/v12"}"#,
        )
        .expect("write fixture command manifest");
        fs::write(root.join("run.ps1"), "").expect("write fixture command entry");
    }

    fn select_update(&self) -> String {
        let runtime_root = self.root.join("home/data/proj.swawkit/runtime");
        let release_id = crate::runtime_release::tests::write_release(
            &self.root.join("home"),
            &runtime_root.join("releases"),
            &[
                ("swawkit-proj.exe", b"updated-core"),
                ("swawkit-proj-host.exe", b"updated-host"),
                ("swawkit-proj-module.exe", b"updated-module"),
                ("swawkit-proj-dev.exe", b"updated-dev"),
            ],
        );
        fs::write(runtime_root.join("current"), format!("{release_id}\n"))
            .expect("select updated Runtime release");
        release_id
    }

    fn command_runs_root(&self) -> PathBuf {
        self.root
            .join("home/data/proj.swawkit/modules/system/demo/_runs")
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn request() -> StartCommandRunRequest {
    StartCommandRunRequest {
        address: ".demo".to_owned(),
        arguments: Vec::new(),
        source: RunJournalSource::Web,
    }
}

#[tokio::test]
async fn missing_entry_config_does_not_gate_command_submission() {
    let fixture = Fixture::new();
    fixture.install_command();
    let runner = Arc::new(RecordingRunner::default());
    let service = RuntimeService::new(
        fixture.context(),
        fixture.data_root_session(),
        runner.clone(),
    );

    let error = match service.submit(request()).await {
        Ok(_) => panic!("recording runner must reject process start"),
        Err(error) => error,
    };

    assert!(matches!(error, RuntimeServiceError::Start(_)));
    assert_eq!(runner.start_count(), 1);
    assert!(fixture.command_runs_root().exists());
}

#[tokio::test]
async fn shutdown_rejects_submit_and_query_with_typed_errors() {
    let fixture = Fixture::new();
    fixture.install_command();
    let runner = Arc::new(RecordingRunner::default());
    let service = RuntimeService::new(
        fixture.context(),
        fixture.data_root_session(),
        runner.clone(),
    );
    service.shutdown().expect("shut down Runtime service");

    let submit_error = match service.submit(request()).await {
        Ok(_) => panic!("shutdown service must reject submission"),
        Err(error) => error,
    };
    assert!(matches!(submit_error, RuntimeServiceError::ShuttingDown));

    let query_error = match service.query(".demo", &[]) {
        Ok(_) => panic!("shutdown service must reject a new query"),
        Err(error) => error,
    };
    assert!(matches!(query_error, RuntimeServiceError::ShuttingDown));
    assert_eq!(runner.start_count(), 0);
    assert!(!fixture.command_runs_root().exists());
}

#[tokio::test]
async fn updated_runtime_rejects_new_work_without_gating_existing_run_controls() {
    let fixture = Fixture::new();
    fixture.install_command();
    let runner = Arc::new(RecordingRunner::default());
    let service = RuntimeService::new(
        fixture.context(),
        fixture.data_root_session(),
        runner.clone(),
    );
    let selected_release_id = fixture.select_update();

    let submit_error = service
        .submit(request())
        .await
        .expect_err("reject stale Host submit");
    assert!(matches!(
        submit_error,
        RuntimeServiceError::RuntimeUpdateRequired {
            ref running_release_id,
            selected_release_id: ref selected,
        } if running_release_id == &fixture.release_id && selected == &selected_release_id
    ));
    let query_error = match service.query(".demo", &[]) {
        Ok(_) => panic!("stale Host query must be rejected"),
        Err(error) => error,
    };
    assert!(matches!(
        query_error,
        RuntimeServiceError::RuntimeUpdateRequired { .. }
    ));

    assert!(matches!(
        service.read("missing", 0),
        Err(RuntimeServiceError::RunNotFound)
    ));
    assert!(matches!(
        service.cancel("missing".to_owned()).await,
        Err(RuntimeServiceError::RunNotFound)
    ));
    assert_eq!(runner.start_count(), 0);
    assert!(!fixture.command_runs_root().exists());
}

#[tokio::test]
async fn invalid_runtime_selector_fails_closed_before_new_work() {
    let fixture = Fixture::new();
    fixture.install_command();
    let runner = Arc::new(RecordingRunner::default());
    let service = RuntimeService::new(
        fixture.context(),
        fixture.data_root_session(),
        runner.clone(),
    );
    fs::write(
        fixture.root.join("home/data/proj.swawkit/runtime/current"),
        "invalid\n",
    )
    .expect("corrupt Runtime selector");

    assert!(matches!(
        service.submit(request()).await,
        Err(RuntimeServiceError::RuntimeGenerationUnavailable(_))
    ));
    assert!(matches!(
        service.query(".demo", &[]),
        Err(RuntimeServiceError::RuntimeGenerationUnavailable(_))
    ));
    assert_eq!(runner.start_count(), 0);
    assert!(!fixture.command_runs_root().exists());
}
