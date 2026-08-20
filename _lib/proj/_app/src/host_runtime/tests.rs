use super::*;
use std::net::TcpListener;
use std::sync::atomic::{AtomicU64, Ordering};

use crate::entry::EntryId;

const ENTRY_ID: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const OTHER_ENTRY_ID: &str = "1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const RELEASE_ID: &str = "0000000000000000000000000000000000000000000000000000000000000000";
const OTHER_RELEASE_ID: &str = "1000000000000000000000000000000000000000000000000000000000000000";
static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    root: PathBuf,
    context: EntryContext,
}

impl Fixture {
    fn new() -> Self {
        let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "swawkit-host-runtime-{}-{sequence}",
            std::process::id()
        ));
        let data_root = root.join("data").join("proj.swawkit");
        let runtime_root = data_root.join("runtime");
        fs::create_dir_all(runtime_root.join("releases").join(RELEASE_ID))
            .expect("create Host runtime fixture");
        let entry_file = root.join("swawkit.exe");
        fs::write(&entry_file, b"launcher").expect("create fixture Entry");
        Self {
            context: EntryContext {
                swawkit_home: root.clone(),
                data_root,
                runtime_root,
                entry_file,
                entry_name: "swawkit".to_owned(),
                entry_id: EntryId::parse(ENTRY_ID).expect("fixture Entry ID"),
                invocation_directory: root.clone(),
                product_executable: root.join("swawkit-proj-host.exe"),
                release_id: RELEASE_ID.to_owned(),
            },
            root,
        }
    }

    fn context_for_release(&self, release_id: &str) -> EntryContext {
        let mut context = self.context.clone();
        context.release_id = release_id.to_owned();
        context
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn instance_key_uses_the_canonical_unicode_data_root_and_entry_id() {
    let fixture = Fixture::new();
    let unicode_root = fixture.root.join("路径-Case");
    fs::create_dir(&unicode_root).expect("create Unicode DataRoot");
    let entry_id = EntryId::parse(ENTRY_ID).unwrap();
    let first = InstanceKey::derive(&unicode_root, &entry_id).unwrap();
    let case_alias = fixture.root.join("路径-case");
    let second = InstanceKey::derive(&case_alias, &entry_id).unwrap();
    let changed =
        InstanceKey::derive(&unicode_root, &EntryId::parse(OTHER_ENTRY_ID).unwrap()).unwrap();

    assert_eq!(first, second);
    assert_ne!(first, changed);
    assert!(is_sha256(first.as_str()));
}

#[test]
fn instance_key_encoding_is_utf16le_nul_then_ascii_entry_id() {
    let entry_id = EntryId::parse(ENTRY_ID).unwrap();
    assert_eq!(
        hash_instance_key(Path::new(r"C:\SWA🌱W\data\proj.项目"), &entry_id),
        "34158bcc8007a8fa3af7cf13681746fd0941405bcd23ae281138b95ea1d60942"
    );
}

#[test]
fn publishes_generation_local_state_and_removes_only_the_current_owner() {
    let fixture = Fixture::new();
    let locator = HostRuntimeLocator::new(&fixture.context).unwrap();
    assert_eq!(
        locator.path(),
        fixture
            .context
            .data_root
            .join("runtime")
            .join("hosts")
            .join(format!("{RELEASE_ID}.json"))
    );
    let first = locator.acquire_owner();
    let first_document = first.document("http://127.0.0.1:43127/").unwrap();
    first.publish(&first_document).unwrap();
    assert_eq!(locator.read().unwrap(), first_document);

    let second = locator.acquire_owner();
    let second_document = second.document("http://127.0.0.1:43128/").unwrap();
    second.publish(&second_document).unwrap();
    drop(first);
    assert_eq!(locator.read().unwrap(), second_document);

    drop(second);
    assert!(!locator.path().exists());
}

#[test]
fn runtime_generations_have_independent_state_files() {
    let fixture = Fixture::new();
    let first = HostRuntimeLocator::new(&fixture.context).unwrap();
    let second = HostRuntimeLocator::new(&fixture.context_for_release(OTHER_RELEASE_ID)).unwrap();
    let first_owner = first.acquire_owner();
    let second_owner = second.acquire_owner();
    first_owner
        .publish(&first_owner.document("http://127.0.0.1:43127/").unwrap())
        .unwrap();
    second_owner
        .publish(&second_owner.document("http://127.0.0.1:43128/").unwrap())
        .unwrap();

    assert_ne!(first.path(), second.path());
    assert_eq!(first.read().unwrap().release_id, RELEASE_ID);
    assert_eq!(second.read().unwrap().release_id, OTHER_RELEASE_ID);
}

#[test]
fn rejects_non_loopback_mismatched_or_unbounded_runtime_state() {
    let fixture = Fixture::new();
    let locator = HostRuntimeLocator::new(&fixture.context).unwrap();
    let owner = locator.acquire_owner();
    assert!(owner.document("http://localhost:43127/").is_err());

    let mut document = owner.document("http://127.0.0.1:43127/").unwrap();
    document.instance_key_sha256 = "1".repeat(64);
    assert!(owner.publish(&document).is_err());

    fs::create_dir_all(locator.path().parent().unwrap()).unwrap();
    fs::write(locator.path(), vec![b'x'; MAX_RUNTIME_BYTES as usize + 1]).unwrap();
    let error = locator.read().unwrap_err();
    assert!(error.to_string().contains("bounded regular file"));
}

#[test]
fn rejects_a_reparse_host_runtime_directory() {
    let fixture = Fixture::new();
    let locator = HostRuntimeLocator::new(&fixture.context).unwrap();
    let external = fixture.root.join("external-hosts");
    fs::create_dir(&external).unwrap();
    if let Err(error) =
        std::os::windows::fs::symlink_dir(&external, locator.path().parent().unwrap())
    {
        eprintln!("skipping Host runtime reparse test: {error}");
        return;
    }

    let error = locator.read().unwrap_err();
    assert!(error.to_string().contains("regular non-reparse directory"));
    fs::remove_dir(locator.path().parent().unwrap()).unwrap();
}

#[test]
fn rejects_a_reparse_or_v1_runtime_document() {
    let fixture = Fixture::new();
    let locator = HostRuntimeLocator::new(&fixture.context).unwrap();
    let owner = locator.acquire_owner();
    let document = owner.document("http://127.0.0.1:43127/").unwrap();
    fs::create_dir_all(locator.path().parent().unwrap()).unwrap();
    let external = fixture.root.join("external-runtime.json");
    fs::write(&external, serde_json::to_vec(&document).unwrap()).unwrap();
    if let Err(error) = std::os::windows::fs::symlink_file(&external, locator.path()) {
        eprintln!("skipping Host runtime state reparse test: {error}");
    } else {
        assert!(locator.read().is_err());
        fs::remove_file(locator.path()).unwrap();
    }

    let mut v1 = document;
    v1.protocol = "swawkit.host-runtime/v1".to_owned();
    fs::write(locator.path(), serde_json::to_vec(&v1).unwrap()).unwrap();
    let error = locator.read().unwrap_err();
    assert!(error.to_string().contains("protocol is unsupported"));
}

#[test]
fn health_probe_requires_boot_entry_instance_and_release_identity() {
    let valid = HealthIdentity::valid();
    let valid_result = probe(&health_fixture(&valid, &valid));
    assert!(valid_result.is_ok(), "{valid_result:?}");

    for response in [
        HealthIdentity {
            boot: "boot-b".to_owned(),
            ..valid.clone()
        },
        HealthIdentity {
            entry: OTHER_ENTRY_ID.to_owned(),
            ..valid.clone()
        },
        HealthIdentity {
            instance: "2".repeat(64),
            ..valid.clone()
        },
        HealthIdentity {
            release: OTHER_RELEASE_ID.to_owned(),
            ..valid.clone()
        },
    ] {
        let error = probe(&health_fixture(&valid, &response)).unwrap_err();
        assert!(error.to_string().contains("identity does not match"));
    }
}

#[derive(Clone)]
struct HealthIdentity {
    entry: String,
    instance: String,
    release: String,
    boot: String,
}

impl HealthIdentity {
    fn valid() -> Self {
        Self {
            entry: ENTRY_ID.to_owned(),
            instance: "1".repeat(64),
            release: RELEASE_ID.to_owned(),
            boot: "boot-a".to_owned(),
        }
    }
}

fn health_fixture(document: &HealthIdentity, response: &HealthIdentity) -> HostRuntimeDocument {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("health fixture listener");
    let address = listener.local_addr().expect("health fixture address");
    let response = response.clone();
    thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("health fixture connection");
        let mut request = Vec::new();
        loop {
            let mut chunk = [0_u8; 256];
            let read = stream.read(&mut chunk).expect("health fixture request");
            request.extend_from_slice(&chunk[..read]);
            if read == 0 || request.windows(4).any(|window| window == b"\r\n\r\n") {
                break;
            }
        }
        write!(
            stream,
            "HTTP/1.1 200 OK\r\n{HOST_BOOT_HEADER}: {}\r\n\
             {HOST_ENTRY_HEADER}: {}\r\n{HOST_INSTANCE_HEADER}: {}\r\n\
             {HOST_RELEASE_HEADER}: {}\r\nContent-Length: 3\r\n\
             Connection: close\r\n\r\nok\n",
            response.boot, response.entry, response.instance, response.release
        )
        .expect("health fixture response");
    });
    HostRuntimeDocument::new(
        document.entry.clone(),
        document.instance.clone(),
        document.release.clone(),
        document.boot.clone(),
        std::process::id(),
        format!("http://{address}/"),
    )
    .expect("health fixture document")
}
