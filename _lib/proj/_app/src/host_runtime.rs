use std::fs;
use std::io::{self, Read, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::atomic_file;
use crate::context::EntryContext;

mod storage;
pub use storage::InstanceKey;
#[cfg(test)]
use storage::hash_instance_key;
use storage::{is_reparse, is_sha256, read_regular_file, regular_directory};

pub const HOST_RUNTIME_PROTOCOL: &str = "swawkit.host-runtime/v3";
pub const HOST_BOOT_HEADER: &str = "x-swawkit-host-boot";
pub const HOST_INSTANCE_HEADER: &str = "x-swawkit-host-instance";
pub const HOST_RELEASE_HEADER: &str = "x-swawkit-host-release";

const MAX_RUNTIME_BYTES: u64 = 16 * 1024;
static NEXT_BOOT: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct HostRuntimeDocument {
    pub protocol: String,
    pub instance_key_sha256: String,
    pub release_id: String,
    pub boot_id: String,
    pub pid: u32,
    pub url: String,
}

impl HostRuntimeDocument {
    pub fn new(
        instance_key_sha256: impl Into<String>,
        release_id: impl Into<String>,
        boot_id: impl Into<String>,
        pid: u32,
        url: impl Into<String>,
    ) -> io::Result<Self> {
        let document = Self {
            protocol: HOST_RUNTIME_PROTOCOL.to_owned(),
            instance_key_sha256: instance_key_sha256.into(),
            release_id: release_id.into(),
            boot_id: boot_id.into(),
            pid,
            url: url.into(),
        };
        document.validate(&document.instance_key_sha256, &document.release_id)?;
        Ok(document)
    }

    pub fn authority(&self) -> io::Result<String> {
        parse_loopback_url(&self.url).map(|address| address.to_string())
    }

    pub fn identity(&self) -> HostRuntimeIdentity {
        HostRuntimeIdentity {
            instance_key_sha256: self.instance_key_sha256.clone(),
            release_id: self.release_id.clone(),
            boot_id: self.boot_id.clone(),
            pid: self.pid,
        }
    }

    fn validate(&self, instance_key: &str, release_id: &str) -> io::Result<()> {
        if self.protocol != HOST_RUNTIME_PROTOCOL {
            return Err(invalid_data("Host runtime protocol is unsupported"));
        }
        if self.instance_key_sha256 != instance_key || !is_sha256(instance_key) {
            return Err(invalid_data("Host runtime Instance key does not match"));
        }
        if self.release_id != release_id || !is_sha256(release_id) {
            return Err(invalid_data("Host runtime Release ID does not match"));
        }
        if !valid_boot_id(&self.boot_id) {
            return Err(invalid_data("Host runtime boot ID is invalid"));
        }
        if self.pid == 0 {
            return Err(invalid_data("Host runtime PID is invalid"));
        }
        parse_loopback_url(&self.url)?;
        Ok(())
    }
}

#[derive(Debug, Clone)]
pub struct HostRuntimeLocator {
    data_root: PathBuf,
    runtime_root: PathBuf,
    hosts_root: PathBuf,
    path: PathBuf,
    instance_key: InstanceKey,
    release_id: String,
}

impl HostRuntimeLocator {
    pub fn new(context: &EntryContext) -> io::Result<Self> {
        if !is_sha256(&context.release_id) {
            return Err(invalid_data("Host Runtime Release ID is invalid"));
        }
        let runtime_root = context.data_root.join("runtime");
        if context.runtime_root != runtime_root {
            return Err(invalid_data(
                "Host Runtime root does not belong to its Entry DataRoot",
            ));
        }
        let hosts_root = runtime_root.join("hosts");
        let instance_key = InstanceKey::derive(&context.data_root)?;
        let path = hosts_root.join(format!("{}.json", context.release_id));
        Ok(Self {
            data_root: context.data_root.clone(),
            runtime_root,
            hosts_root,
            path,
            instance_key,
            release_id: context.release_id.clone(),
        })
    }

    pub fn acquire_owner(&self) -> HostRuntimeOwner {
        HostRuntimeOwner {
            locator: self.clone(),
            identity: HostRuntimeIdentity {
                instance_key_sha256: self.instance_key.as_str().to_owned(),
                release_id: self.release_id.clone(),
                boot_id: unique_boot_id(),
                pid: std::process::id(),
            },
        }
    }

    pub fn read(&self) -> io::Result<HostRuntimeDocument> {
        self.validate_storage()?;
        let bytes = read_regular_file(&self.path, MAX_RUNTIME_BYTES)?;
        let document: HostRuntimeDocument = serde_json::from_slice(&bytes)
            .map_err(|error| invalid_data(format!("Host runtime document is invalid: {error}")))?;
        self.validate_document(&document)?;
        Ok(document)
    }

    pub fn wait_for_healthy(&self, timeout: Duration) -> io::Result<HostRuntimeDocument> {
        let deadline = Instant::now() + timeout;
        loop {
            let error = match self.read().and_then(|document| {
                probe(&document)?;
                Ok(document)
            }) {
                Ok(document) => return Ok(document),
                Err(error) => error,
            };
            if Instant::now() >= deadline {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    format!(
                        "the existing Entry Host did not publish a healthy control endpoint: {error}"
                    ),
                ));
            }
            thread::sleep(Duration::from_millis(50));
        }
    }

    pub fn instance_key(&self) -> &InstanceKey {
        &self.instance_key
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn validate_document(&self, document: &HostRuntimeDocument) -> io::Result<()> {
        document.validate(self.instance_key.as_str(), &self.release_id)
    }

    fn validate_storage(&self) -> io::Result<()> {
        regular_directory(&self.data_root, "Entry DataRoot")?;
        regular_directory(&self.runtime_root, "Entry Runtime directory")?;
        regular_directory(&self.hosts_root, "Host runtime directory")
    }

    fn prepare_storage(&self) -> io::Result<()> {
        regular_directory(&self.data_root, "Entry DataRoot")?;
        regular_directory(&self.runtime_root, "Entry Runtime directory")?;
        match fs::create_dir(&self.hosts_root) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error),
        }
        regular_directory(&self.hosts_root, "Host runtime directory")?;
        match fs::symlink_metadata(&self.path) {
            Ok(metadata) if metadata.is_file() && !is_reparse(&metadata) => Ok(()),
            Ok(_) => Err(invalid_data(format!(
                "Host runtime state must be a regular non-reparse file: {}",
                self.path.display()
            ))),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error),
        }
    }
}

pub struct HostRuntimeOwner {
    locator: HostRuntimeLocator,
    identity: HostRuntimeIdentity,
}

#[derive(Debug, Clone)]
pub struct HostRuntimeIdentity {
    instance_key_sha256: String,
    release_id: String,
    boot_id: String,
    pid: u32,
}

impl HostRuntimeIdentity {
    pub fn document(&self, url: impl Into<String>) -> io::Result<HostRuntimeDocument> {
        HostRuntimeDocument::new(
            self.instance_key_sha256.clone(),
            self.release_id.clone(),
            self.boot_id.clone(),
            self.pid,
            url,
        )
    }
}

impl HostRuntimeOwner {
    pub fn document(&self, url: impl Into<String>) -> io::Result<HostRuntimeDocument> {
        self.identity.document(url)
    }

    pub fn identity(&self) -> HostRuntimeIdentity {
        self.identity.clone()
    }

    pub fn publish(&self, document: &HostRuntimeDocument) -> io::Result<()> {
        if document.instance_key_sha256 != self.identity.instance_key_sha256
            || document.release_id != self.identity.release_id
            || document.boot_id != self.identity.boot_id
            || document.pid != self.identity.pid
        {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "cannot publish a Host runtime document owned by another generation",
            ));
        }
        self.locator.validate_document(document)?;
        self.locator.prepare_storage()?;
        let content = serde_json::to_vec_pretty(document)
            .map_err(|error| invalid_data(format!("cannot encode Host runtime: {error}")))?;
        atomic_file::publish(&self.locator.path, &content)
    }

    pub fn locator(&self) -> &HostRuntimeLocator {
        &self.locator
    }
}

impl Drop for HostRuntimeOwner {
    fn drop(&mut self) {
        let should_remove = self.locator.read().is_ok_and(|document| {
            document.boot_id == self.identity.boot_id && document.pid == self.identity.pid
        });
        if should_remove {
            let _ = fs::remove_file(&self.locator.path);
        }
    }
}

fn probe(document: &HostRuntimeDocument) -> io::Result<()> {
    let address = parse_loopback_url(&document.url)?;
    let mut stream = TcpStream::connect_timeout(&address, Duration::from_millis(350))?;
    stream.set_read_timeout(Some(Duration::from_millis(350)))?;
    stream.set_write_timeout(Some(Duration::from_millis(350)))?;
    write!(
        stream,
        "GET /healthz HTTP/1.1\r\nHost: {}\r\nConnection: close\r\n\r\n",
        address
    )?;

    let mut response = String::new();
    stream.take(16 * 1024).read_to_string(&mut response)?;
    let headers = response
        .split_once("\r\n\r\n")
        .map(|(headers, _)| headers)
        .ok_or_else(|| invalid_data("Host health response has no header boundary"))?;
    let mut lines = headers.lines();
    if !lines
        .next()
        .is_some_and(|line| line.starts_with("HTTP/1.1 200 "))
    {
        return Err(invalid_data("Host health response is not HTTP 200"));
    }
    let boot_id = response_header(lines.clone(), HOST_BOOT_HEADER);
    let instance_key = response_header(lines.clone(), HOST_INSTANCE_HEADER);
    let release_id = response_header(lines, HOST_RELEASE_HEADER);
    if boot_id.as_deref() != Some(document.boot_id.as_str())
        || instance_key.as_deref() != Some(document.instance_key_sha256.as_str())
        || release_id.as_deref() != Some(document.release_id.as_str())
    {
        return Err(invalid_data(
            "Host health identity does not match runtime state",
        ));
    }
    Ok(())
}

fn response_header<'a>(lines: impl Iterator<Item = &'a str>, name: &str) -> Option<String> {
    lines
        .filter_map(|line| line.split_once(':'))
        .find_map(|(key, value)| {
            key.eq_ignore_ascii_case(name)
                .then(|| value.trim().to_owned())
        })
}

fn parse_loopback_url(url: &str) -> io::Result<SocketAddr> {
    let authority = url
        .strip_prefix("http://127.0.0.1:")
        .and_then(|value| value.strip_suffix('/'))
        .filter(|value| {
            !value.is_empty() && value.chars().all(|character| character.is_ascii_digit())
        })
        .ok_or_else(|| invalid_data("Host runtime URL must be an exact IPv4 loopback URL"))?;
    let port = authority
        .parse::<u16>()
        .ok()
        .filter(|port| *port != 0)
        .ok_or_else(|| invalid_data("Host runtime URL port is invalid"))?;
    Ok(SocketAddr::from((Ipv4Addr::LOCALHOST, port)))
}

fn valid_boot_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 160
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
}

fn unique_boot_id() -> String {
    let sequence = NEXT_BOOT.fetch_add(1, Ordering::Relaxed);
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    format!("{}-{timestamp}-{sequence}", std::process::id())
}

fn invalid_data(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}

#[cfg(test)]
mod tests;
