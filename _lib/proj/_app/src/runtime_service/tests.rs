use std::fs;
use std::io;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};

use super::*;
use crate::data_root::{DataRootSession, ResolveDataRootRequest, resolve_data_root};
use crate::entry::EntryId;
use crate::process_runner::{ProcessControl, ProcessObserver};
use crate::profile::{EntryProfileRecord, EntryProfileStore};
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
        EntryId::create_once(&data_root).expect("create fixture Entry ID");
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
            entry_id: EntryId::read(&data_root).expect("read fixture Entry ID"),
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
            r#"{"schema":"swawkit.command-module/v11"}"#,
        )
        .expect("write fixture command manifest");
        fs::write(root.join("run.ps1"), "").expect("write fixture command entry");
    }

    fn save_profile(&self) {
        EntryProfileStore::new(
            self.root.join("home"),
            self.root.join("home/data/proj.swawkit"),
        )
        .save(EntryProfileRecord::default())
        .expect("save fixture profile");
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
async fn preparation_failure_happens_before_runner_or_journal() {
    let fixture = Fixture::new();
    fixture.install_command();
    let runner = Arc::new(RecordingRunner::default());
    let service = RuntimeService::new(
        fixture.context(),
        fixture.data_root_session(),
        runner.clone(),
    );

    let error = match service.submit(request()).await {
        Ok(_) => panic!("a missing profile must reject command preparation"),
        Err(error) => error,
    };

    assert!(matches!(error, RuntimeServiceError::ProfileSetupRequired));
    assert_eq!(runner.start_count(), 0);
    assert!(!fixture.command_runs_root().exists());
}

#[tokio::test]
async fn shutdown_rejects_submit_and_query_with_typed_errors() {
    let fixture = Fixture::new();
    fixture.install_command();
    fixture.save_profile();
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
