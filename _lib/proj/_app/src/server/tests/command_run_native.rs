use std::env;
use std::fs;
use std::io;
use std::os::windows::io::{FromRawHandle, OwnedHandle};
use std::path::Path;
use std::time::{Duration, Instant};

use axum::body::{Body, to_bytes};
use axum::http::{Method, Request, header::LOCATION};
use serde_json::{Value, json};
use tower::ServiceExt;
use windows_sys::Win32::Foundation::{HANDLE, WAIT_OBJECT_0, WAIT_TIMEOUT};
use windows_sys::Win32::System::Threading::{
    OpenProcess, PROCESS_SYNCHRONIZE, WaitForSingleObject,
};

use super::*;
use crate::entry_config::EntryConfigRecord;
use crate::runtime_service::RuntimeService;

const NORMAL_ACTION: &str = "swaw/webdirectnormal";
const CANCEL_ACTION: &str = "swaw/webdirectcancel";
const NORMAL_MARKER: &str = "web-direct-command.marker";
const CANCEL_PID_MARKER: &str = "web-direct-command-descendant.pid";
const STDOUT_SENTINEL: &str = "SWAWKIT_WEB_DIRECT_STDOUT_SENTINEL";
const STDERR_SENTINEL: &str = "SWAWKIT_WEB_DIRECT_STDERR_SENTINEL";
const PROGRESS_FRAME: &str = "\u{001e}swawkit-event-v1 {\"schema\":\"swawkit.command-event/v1\",\"kind\":\"progress\",\"id\":\"download:fixture.zip\",\"state\":\"completed\",\"current\":42,\"total\":42,\"unit\":\"bytes\",\"message\":\"Downloaded fixture.zip\"}";
const TEST_TIMEOUT: Duration = Duration::from_secs(10);

#[tokio::test]
async fn executes_and_cancels_direct_commands_through_the_http_router() {
    let fixture = Fixture::new();
    fixture.directory("home/_lib/proj");
    let normal_root = fixture.directory("home/_lib/proj/modules/webdirectnormal");
    let cancel_root = fixture.directory("home/_lib/proj/modules/webdirectcancel");
    for command_root in [&normal_root, &cancel_root] {
        fs::write(
            command_root.join("swawkit.module.json"),
            r#"{"schema":"swawkit.command-module/v12"}"#,
        )
        .expect("write direct command manifest");
    }
    install_command_executable(&normal_root.join("run.exe"));
    install_command_executable(&cancel_root.join("run.exe"));
    let normal_script = normal_root.join("fixture.cmd");
    let cancel_script = cancel_root.join("fixture.cmd");
    fs::write(
        &normal_script,
        format!(
            "@echo off\r\nif not \"%SWAWKIT_PROJ_CORE_COMMAND_PROTOCOL%\"==\"{}\" exit /b 91\r\nif not \"%SWAWKIT_PROJ_CORE_COMMAND_ADDRESS%\"==\"{NORMAL_ACTION}\" exit /b 92\r\nif /I not \"%CD%\"==\"%SWAWKIT_PROJ_CORE_COMMAND_INVOCATION_DIR%\" exit /b 93\r\n>\"{NORMAL_MARKER}\" echo command cwd reached\r\necho {STDOUT_SENTINEL}\r\n1>&2 echo {PROGRESS_FRAME}\r\n1>&2 echo {STDERR_SENTINEL}\r\n",
            swawkit_proj_protocol::COMMAND_ENVIRONMENT_PROTOCOL,
        ),
    )
    .expect("write normal direct command script");
    fs::write(
        &cancel_script,
        format!(
            "@echo off\r\npowershell.exe -NoLogo -NoProfile -NonInteractive -Command \"[IO.File]::WriteAllText('{CANCEL_PID_MARKER}', $PID.ToString()); Start-Sleep -Seconds 60\"\r\n",
        ),
    )
    .expect("write cancel direct command script");
    fixture
        .config_store()
        .save(EntryConfigRecord::default())
        .expect("save direct command fixture Entry Config");

    let context = fixture.context();
    let data_root = fixture.data_root_session();
    let runtime_service = RuntimeService::native(context.clone(), data_root.clone());
    let host_runtime = test_host_runtime(&context);
    let app = router_with_runtime_service(
        AUTHORITY.to_owned(),
        context,
        data_root,
        runtime_service.clone(),
        host_runtime,
        HostControl::new(),
    );

    let (normal_location, normal_created) =
        start_native_run(&app, NORMAL_ACTION, &normal_script).await;
    assert_eq!(normal_created["address"], NORMAL_ACTION);
    let normal = wait_for_terminal(&app, &normal_location).await;
    assert_eq!(normal["state"], "exited");
    assert_eq!(normal["exitCode"], 0);
    assert_eq!(normal["error"], Value::Null);
    assert_eq!(
        fs::read_to_string(fixture.root.join("home").join(NORMAL_MARKER))
            .expect("read direct command cwd marker"),
        "command cwd reached\r\n"
    );
    let (stdout, stderr) = output_text(&normal);
    assert!(stdout.contains(STDOUT_SENTINEL), "stdout was: {stdout:?}");
    assert!(stderr.contains(STDERR_SENTINEL), "stderr was: {stderr:?}");
    let progress = normal["events"]
        .as_array()
        .expect("native run events")
        .iter()
        .find(|event| event["kind"] == "progress")
        .expect("direct command progress event");
    assert_eq!(progress["id"], "download:fixture.zip");
    assert_eq!(progress["state"], "completed");
    assert_eq!(progress["current"], 42);
    assert_eq!(progress["total"], 42);

    let (cancel_location, cancel_created) =
        start_native_run(&app, CANCEL_ACTION, &cancel_script).await;
    assert_eq!(cancel_created["state"], "running");
    let descendant_pid = wait_for_pid_file(&fixture.root.join("home").join(CANCEL_PID_MARKER));
    let descendant = open_process_for_wait(descendant_pid);
    assert_eq!(
        unsafe { WaitForSingleObject(raw_handle(&descendant), 0) },
        WAIT_TIMEOUT,
        "direct command descendant exited before cancellation"
    );

    let canceled = send(
        app.clone(),
        Method::DELETE,
        &cancel_location,
        Some(AUTHORITY),
    )
    .await;
    assert_eq!(canceled.status(), StatusCode::NO_CONTENT);
    let canceled = wait_for_terminal(&app, &cancel_location).await;
    assert_eq!(canceled["state"], "canceled");
    assert_eq!(canceled["exitCode"], Value::Null);
    assert_eq!(canceled["error"], Value::Null);
    assert_eq!(
        unsafe { WaitForSingleObject(raw_handle(&descendant), TEST_TIMEOUT.as_millis() as u32,) },
        WAIT_OBJECT_0,
        "DELETE did not terminate the direct command descendant"
    );

    runtime_service
        .shutdown()
        .expect("shut down native command runs");
}

fn install_command_executable(target: &Path) {
    let source_path = env::var_os("ComSpec").expect("resolve the system command interpreter");
    let source_path = Path::new(&source_path);
    fs::copy(&source_path, target).unwrap_or_else(|error| {
        panic!(
            "copy system command interpreter '{}' to '{}': {error}",
            source_path.display(),
            target.display()
        )
    });
}

async fn start_native_run(app: &Router, address: &str, script: &Path) -> (String, Value) {
    let arguments = vec![
        "/d".to_owned(),
        "/c".to_owned(),
        script.to_string_lossy().into_owned(),
    ];
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/api/v2/command-runs")
                .header(HOST, AUTHORITY)
                .header(CONTENT_TYPE, "application/json")
                .body(Body::from(
                    json!({
                        "address": address,
                        "arguments": arguments
                    })
                    .to_string(),
                ))
                .expect("valid native command run request"),
        )
        .await
        .expect("native command run response");
    assert_eq!(response.status(), StatusCode::CREATED);
    let location = response
        .headers()
        .get(LOCATION)
        .expect("native command run Location")
        .to_str()
        .expect("native command run Location text")
        .to_owned();
    let document = response_json(response).await;
    (location, document)
}

async fn wait_for_terminal(app: &Router, location: &str) -> Value {
    let deadline = Instant::now() + TEST_TIMEOUT;
    loop {
        let response = send(app.clone(), Method::GET, location, Some(AUTHORITY)).await;
        assert_eq!(response.status(), StatusCode::OK);
        let document = response_json(response).await;
        if matches!(
            document["state"].as_str(),
            Some("exited" | "canceled" | "failed")
        ) {
            return document;
        }
        assert!(
            Instant::now() < deadline,
            "native command run did not reach a terminal state: {document}"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

async fn response_json(response: Response) -> Value {
    let body = to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("native command run response body");
    serde_json::from_slice(&body).expect("native command run response JSON")
}

fn output_text(document: &Value) -> (String, String) {
    let mut stdout = String::new();
    let mut stderr = String::new();
    for event in document["events"].as_array().expect("native output events") {
        if event["kind"] != "output" {
            continue;
        }
        let text = event["text"].as_str().expect("native output event text");
        match event["stream"].as_str() {
            Some("stdout") => stdout.push_str(text),
            Some("stderr") => stderr.push_str(text),
            stream => panic!("unexpected native output stream: {stream:?}"),
        }
    }
    (stdout, stderr)
}

fn wait_for_pid_file(path: &std::path::Path) -> u32 {
    let deadline = Instant::now() + TEST_TIMEOUT;
    loop {
        match fs::read_to_string(path) {
            Ok(pid) => return pid.parse().expect("native worker descendant PID"),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => panic!(
                "read native worker descendant PID '{}': {error}",
                path.display()
            ),
        }
        assert!(
            Instant::now() < deadline,
            "direct command did not publish its descendant PID"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn open_process_for_wait(pid: u32) -> OwnedHandle {
    let handle = unsafe { OpenProcess(PROCESS_SYNCHRONIZE, 0, pid) };
    assert!(
        !handle.is_null(),
        "open direct command descendant {pid}: {}",
        io::Error::last_os_error()
    );
    unsafe { OwnedHandle::from_raw_handle(handle) }
}

fn raw_handle(handle: &OwnedHandle) -> HANDLE {
    use std::os::windows::io::AsRawHandle;
    handle.as_raw_handle() as HANDLE
}
