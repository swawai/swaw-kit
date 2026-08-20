#[cfg(not(target_os = "windows"))]
compile_error!("The Swaw Kit Proj Host V0 supports Windows only.");

#[path = "../host_instance.rs"]
mod host_instance;
#[path = "../tray.rs"]
mod tray;

use std::error::Error;
use std::ffi::OsStr;
use std::os::windows::ffi::OsStrExt;
use std::time::Duration;

use swawkit_proj::{
    context::EntryContext,
    data_root::{DataRootSession, ResolveDataRootRequest},
    host_restart::HostRestartRequest,
    host_runtime::HostRuntimeLocator,
    launch::{LaunchMode, LaunchRequest, clear_inherited_swawkit_environment},
    runtime_release,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{MB_ICONERROR, MB_OK, MessageBoxW};

use crate::host_instance::{HostInstance, HostInstanceAcquisition};

fn main() {
    let result = HostRestartRequest::from_process()
        .map_err(Into::into)
        .and_then(|restart| {
            LaunchRequest::from_process()
                .map_err(Into::into)
                .and_then(|request| run(request, restart))
        });
    if let Err(error) = result {
        eprintln!("[ERROR] {error}");
        show_host_error(&error.to_string());
        std::process::exit(1);
    }
}

fn run(request: LaunchRequest, restart: Option<HostRestartRequest>) -> Result<(), Box<dyn Error>> {
    if request.mode != LaunchMode::InternalHost || !request.argv.is_empty() {
        return Err(format!(
            "the Host accepts only the '{}' launch mode without arguments",
            LaunchMode::InternalHost.as_env_value()
        )
        .into());
    }
    // SAFETY: this is the Host composition root and no thread exists yet.
    unsafe { clear_inherited_swawkit_environment() };
    let context = EntryContext::from_host_launch(&request)?;
    runtime_release::validate_running_release(&context)?;
    let data_root = pin_entry_data_root(&context)?;
    if let Some(restart) = restart {
        let result = restart.complete(&context).map_err(Into::into);
        drop(data_root);
        return result;
    }
    let runtime = HostRuntimeLocator::new(&context)?;
    let instance = match HostInstance::acquire(runtime.instance_key(), &context.release_id)? {
        HostInstanceAcquisition::Primary(instance) => instance,
        HostInstanceAcquisition::Existing => {
            let document = runtime.wait_for_healthy(Duration::from_secs(5))?;
            webbrowser::open(&document.url)
                .map_err(|error| format!("cannot activate the existing Entry Host: {error}"))?;
            return Ok(());
        }
    };
    tray::run(context, data_root, instance, runtime.acquire_owner())?;
    Ok(())
}

fn pin_entry_data_root(context: &EntryContext) -> Result<DataRootSession, Box<dyn Error>> {
    let data_root = DataRootSession::new(ResolveDataRootRequest {
        swawkit_home: &context.swawkit_home,
        entry_file: &context.entry_file,
    })?;
    let resolved_data_root = data_root.resolved();
    if resolved_data_root.path() != context.data_root {
        return Err(format!(
            "the Host resolved a different Entry DataRoot: expected '{}', received '{}'",
            context.data_root.display(),
            resolved_data_root.path().display()
        )
        .into());
    }
    if resolved_data_root.entry_id() != &context.entry_id {
        return Err(format!(
            "the Host resolved a different Entry ID: expected {}, received {}",
            context.entry_id,
            resolved_data_root.entry_id()
        )
        .into());
    }
    Ok(data_root)
}

fn show_host_error(error: &str) {
    let title = null_terminated("Swaw Kit 无法打开");
    let message = null_terminated(&format!(
        "无法启动或激活 Swaw Kit 控制台。\n\n{error}\n\n请稍后重试；该错误不会被静默忽略。"
    ));
    unsafe {
        MessageBoxW(
            std::ptr::null_mut(),
            message.as_ptr(),
            title.as_ptr(),
            MB_OK | MB_ICONERROR,
        );
    }
}

fn null_terminated(value: &str) -> Vec<u16> {
    OsStr::new(value)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    use swawkit_proj::entry::EntryId;

    static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);
    const LAUNCH_ENTRY_ID: &str =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const REPLACEMENT_ENTRY_ID: &str =
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    struct Fixture {
        root: PathBuf,
        context: EntryContext,
    }

    impl Fixture {
        fn new() -> Self {
            let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
            let root = std::env::temp_dir().join(format!(
                "swawkit-host-entry-pin-{}-{sequence}",
                std::process::id()
            ));
            let data_root = root.join("data/proj.entry");
            fs::create_dir_all(&data_root).expect("create Entry DataRoot");
            let entry_file = root.join("entry.exe");
            fs::write(&entry_file, b"launcher").expect("create Entry Launcher");
            fs::write(data_root.join("entry.id"), format!("{LAUNCH_ENTRY_ID}\n"))
                .expect("create Entry ID");
            Self {
                context: EntryContext {
                    swawkit_home: root.clone(),
                    data_root: data_root.clone(),
                    runtime_root: data_root.join("runtime"),
                    entry_file,
                    entry_name: "entry".to_owned(),
                    entry_id: EntryId::parse(LAUNCH_ENTRY_ID).expect("parse launch Entry ID"),
                    invocation_directory: root.clone(),
                    product_executable: root.join("swawkit-proj-host.exe"),
                    release_id: "c".repeat(64),
                },
                root,
            }
        }

        fn entry_id_path(&self) -> PathBuf {
            self.context.data_root.join("entry.id")
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    #[test]
    fn restart_does_not_enter_launcher_start_after_the_entry_id_is_replaced() {
        let fixture = Fixture::new();
        fs::write(fixture.entry_id_path(), format!("{REPLACEMENT_ENTRY_ID}\n"))
            .expect("replace Entry ID after LaunchRequest validation");
        let launcher_start_entered = Cell::new(false);

        let result = pin_entry_data_root(&fixture.context).map(|data_root| {
            launcher_start_entered.set(true);
            drop(data_root);
        });

        let error = result.expect_err("a replaced Entry ID must fail before restart completion");
        assert!(error.to_string().contains("resolved a different Entry ID"));
        assert!(!launcher_start_entered.get());
    }

    #[test]
    fn entry_id_stays_pinned_until_restart_completion_returns() {
        let fixture = Fixture::new();
        let data_root = pin_entry_data_root(&fixture.context).expect("pin Entry identity");

        let replacement = fs::write(fixture.entry_id_path(), format!("{REPLACEMENT_ENTRY_ID}\n"));
        assert!(replacement.is_err(), "the pinned Entry ID was replaceable");

        drop(data_root);
        fs::write(fixture.entry_id_path(), format!("{REPLACEMENT_ENTRY_ID}\n"))
            .expect("replace Entry ID after releasing the pin");
    }
}
