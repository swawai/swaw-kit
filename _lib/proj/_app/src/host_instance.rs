use std::ffi::OsStr;
use std::io;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::{FromRawHandle, OwnedHandle};

use swawkit_proj::host_runtime::InstanceKey;
use windows_sys::Win32::Foundation::{ERROR_ALREADY_EXISTS, GetLastError, HANDLE, SetLastError};
use windows_sys::Win32::System::Threading::CreateEventW;

const INSTANCE_NAME_PREFIX: &str = r"Local\SwawKit.Proj.Host.";

pub enum HostInstanceAcquisition {
    Primary(HostInstance),
    Existing,
}

pub struct HostInstance {
    _lease: OwnedHandle,
}

impl HostInstance {
    pub fn acquire(
        instance_key: &InstanceKey,
        release_id: &str,
    ) -> io::Result<HostInstanceAcquisition> {
        if !is_sha256(release_id) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Host Runtime Release ID is invalid",
            ));
        }
        // This is an atomic per-session lease for one immutable Runtime
        // generation. Different releases may coexist during an upgrade.
        let name = null_terminated(&format!(
            "{INSTANCE_NAME_PREFIX}{}.{}",
            instance_key.as_str(),
            release_id
        ));
        unsafe { SetLastError(0) };
        let handle = unsafe { CreateEventW(std::ptr::null(), 0, 0, name.as_ptr()) };
        let creation_error = unsafe { GetLastError() };
        let lease = owned_handle(handle, "create the Entry Host generation lease")?;

        if creation_error == ERROR_ALREADY_EXISTS {
            return Ok(HostInstanceAcquisition::Existing);
        }

        Ok(HostInstanceAcquisition::Primary(Self { _lease: lease }))
    }
}

fn null_terminated(value: &str) -> Vec<u16> {
    OsStr::new(value)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}

fn owned_handle(handle: HANDLE, action: &str) -> io::Result<OwnedHandle> {
    if handle.is_null() {
        let error = io::Error::last_os_error();
        return Err(io::Error::new(
            error.kind(),
            format!("cannot {action}: {error}"),
        ));
    }
    Ok(unsafe { OwnedHandle::from_raw_handle(handle) })
}

fn is_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    const TEST_INSTANCE_KEY_ENV: &str = "SWAWKIT_PROJ_TEST_HOST_INSTANCE_KEY";
    const TEST_RELEASE_ID_ENV: &str = "SWAWKIT_PROJ_TEST_HOST_RELEASE_ID";
    static NEXT_GENERATION: AtomicU64 = AtomicU64::new(1);

    #[test]
    fn a_second_claim_observes_the_existing_generation() {
        let (instance_key, release_id) = unique_generation();
        let HostInstanceAcquisition::Primary(_primary) =
            HostInstance::acquire(&instance_key, &release_id).unwrap()
        else {
            panic!("the first claim must become primary");
        };

        assert!(matches!(
            HostInstance::acquire(&instance_key, &release_id).unwrap(),
            HostInstanceAcquisition::Existing
        ));
    }

    #[test]
    fn different_instances_and_releases_have_independent_hosts() {
        let (first_key, first_release) = unique_generation();
        let (second_key, second_release) = unique_generation();
        let alternate_release = format!("{:064x}", NEXT_GENERATION.fetch_add(1, Ordering::Relaxed));

        let HostInstanceAcquisition::Primary(first) =
            HostInstance::acquire(&first_key, &first_release).unwrap()
        else {
            panic!("the first generation must have its own primary");
        };
        let HostInstanceAcquisition::Primary(second) =
            HostInstance::acquire(&second_key, &second_release).unwrap()
        else {
            panic!("the second instance must have its own primary");
        };
        let HostInstanceAcquisition::Primary(alternate) =
            HostInstance::acquire(&first_key, &alternate_release).unwrap()
        else {
            panic!("the alternate release must have its own primary");
        };

        assert!(matches!(
            HostInstance::acquire(&first_key, &first_release).unwrap(),
            HostInstanceAcquisition::Existing
        ));
        drop((first, second, alternate));
    }

    #[test]
    fn releasing_the_primary_allows_a_new_primary() {
        let (instance_key, release_id) = unique_generation();
        let HostInstanceAcquisition::Primary(primary) =
            HostInstance::acquire(&instance_key, &release_id).unwrap()
        else {
            panic!("the first claim must become primary");
        };
        drop(primary);

        assert!(matches!(
            HostInstance::acquire(&instance_key, &release_id).unwrap(),
            HostInstanceAcquisition::Primary(_)
        ));
    }

    #[test]
    fn another_process_observes_the_existing_generation() {
        let (instance_key, release_id) = unique_generation();
        let HostInstanceAcquisition::Primary(_primary) =
            HostInstance::acquire(&instance_key, &release_id).unwrap()
        else {
            panic!("the parent process must become primary");
        };

        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "host_instance::tests::subprocess_existing_helper",
                "--nocapture",
            ])
            .env(TEST_INSTANCE_KEY_ENV, instance_key.as_str())
            .env(TEST_RELEASE_ID_ENV, &release_id)
            .output()
            .expect("start the secondary test process");
        assert!(
            output.status.success(),
            "secondary process failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    #[test]
    fn subprocess_existing_helper() {
        let (Some(instance_key), Some(release_id)) = (
            std::env::var_os(TEST_INSTANCE_KEY_ENV),
            std::env::var_os(TEST_RELEASE_ID_ENV),
        ) else {
            return;
        };
        let instance_key = InstanceKey::parse(instance_key.to_string_lossy()).unwrap();

        assert!(matches!(
            HostInstance::acquire(&instance_key, &release_id.to_string_lossy()).unwrap(),
            HostInstanceAcquisition::Existing
        ));
    }

    fn unique_generation() -> (InstanceKey, String) {
        let sequence = NEXT_GENERATION.fetch_add(1, Ordering::Relaxed);
        let key = format!(
            "{:064x}",
            ((std::process::id() as u128) << 64) | sequence as u128
        );
        let release_id = format!("{:064x}", sequence + 1_000_000);
        (InstanceKey::parse(key).unwrap(), release_id)
    }
}
