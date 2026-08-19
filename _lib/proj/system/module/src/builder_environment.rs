use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::path::{Component, Path, PathBuf};
use std::process::Command;

use swawkit_proj_protocol::serde::{self, Deserialize};
use swawkit_proj_protocol::{is_sha256, revision, serde_json, sha256_hex};

use crate::filesystem::{checked_directory, read_regular_file, regular_directory};

const ENVIRONMENT_SCHEMA: &str = "swawkit.proj-bootstrap-environment/v1";
const BOOTSTRAP_CONTRACT_SCHEMA: &str = "swawkit.proj-bootstrap/v1";
const MAX_DOCUMENT_BYTES: u64 = 1024 * 1024;
const MAX_TOOL_BYTES: u64 = 512 * 1024 * 1024;
const ENVIRONMENT_VARIABLES: [&str; 25] = [
    "CARGO_BUILD_RUSTC",
    "CARGO_BUILD_RUSTDOC",
    "CARGO_HOME",
    "INCLUDE",
    "LIB",
    "RUSTC",
    "RUSTDOC",
    "RUSTUP_DIST_ROOT",
    "RUSTUP_DIST_SERVER",
    "RUSTUP_HOME",
    "RUSTUP_TOOLCHAIN",
    "RUSTUP_TOOLCHAIN_SOURCE",
    "RUSTUP_UPDATE_ROOT",
    "RUSTUP_VERSION",
    "UCRTVersion",
    "UniversalCRTSdkDir",
    "VCINSTALLDIR",
    "VCToolsInstallDir",
    "VCToolsVersion",
    "VSCMD_ARG_HOST_ARCH",
    "VSCMD_ARG_TGT_ARCH",
    "WindowsSDKVersion",
    "WindowsSdkBinPath",
    "WindowsSdkDir",
    "WindowsSdkVerBinPath",
];

pub(crate) struct BuilderEnvironment {
    cargo: PathBuf,
    variables: BTreeMap<String, Option<String>>,
    path_prefixes: Vec<PathBuf>,
}

impl BuilderEnvironment {
    pub(crate) fn load(swawkit_home: &Path) -> Result<Self, String> {
        Self::load_inner(swawkit_home).map_err(|error| {
            format!(
                "Bootstrap Native builder environment is unavailable: {error}. Run '{}'",
                swawkit_home
                    .join("_lib")
                    .join("proj")
                    .join("_bootstrap")
                    .join("setup.ps1")
                    .display()
            )
        })
    }

    fn load_inner(swawkit_home: &Path) -> Result<Self, String> {
        let kernel_root =
            checked_directory(swawkit_home, ["_lib", "proj"], "Proj command source root")?;
        let bootstrap_root = checked_directory(
            swawkit_home,
            ["data", "proj_cache", "bootstrap"],
            "Bootstrap data root",
        )?;
        let toolchain_root =
            checked_directory(&bootstrap_root, ["toolchains"], "Bootstrap toolchain root")?;
        let contract_path = kernel_root.join("bootstrap.json");
        let contract_bytes =
            read_regular_file(&contract_path, "Bootstrap contract", MAX_DOCUMENT_BYTES)?;
        let contract: BootstrapContract = serde_json::from_slice(&contract_bytes)
            .map_err(|error| format!("invalid Bootstrap contract: {error}"))?;
        if contract.schema != BOOTSTRAP_CONTRACT_SCHEMA {
            return Err(format!(
                "unsupported Bootstrap contract '{}'; expected '{BOOTSTRAP_CONTRACT_SCHEMA}'",
                contract.schema
            ));
        }

        let document_path = bootstrap_root.join("environment.json");
        let document_bytes = read_regular_file(
            &document_path,
            "Bootstrap builder environment",
            MAX_DOCUMENT_BYTES,
        )?;
        let document: EnvironmentDocument = serde_json::from_slice(&document_bytes)
            .map_err(|error| format!("invalid Bootstrap builder environment: {error}"))?;
        if document.schema != ENVIRONMENT_SCHEMA
            || document.contract != contract
            || document.contract_revision != revision(&contract_bytes)
            || !valid_environment_revision(&document.environment_revision)
        {
            return Err("Bootstrap builder environment does not match bootstrap.json".to_owned());
        }
        validate_variables(&document.variables, &toolchain_root)?;
        let cargo = validate_tool(
            &toolchain_root,
            &document.tools.cargo,
            "cargo.exe",
            "Bootstrap Cargo",
        )?;
        let rustc = validate_tool(
            &toolchain_root,
            &document.tools.rustc,
            "rustc.exe",
            "Bootstrap Rust compiler",
        )?;
        let compiler = validate_tool(
            &toolchain_root,
            &document.tools.compiler,
            "cl.exe",
            "Bootstrap C compiler",
        )?;
        let linker = validate_tool(
            &toolchain_root,
            &document.tools.linker,
            "link.exe",
            "Bootstrap linker",
        )?;
        for name in ["RUSTC", "CARGO_BUILD_RUSTC"] {
            if document.variables.get(name).and_then(Option::as_deref)
                != Some(rustc.to_string_lossy().as_ref())
            {
                return Err(format!("Bootstrap builder environment has a stale {name}"));
            }
        }
        let cargo_home = PathBuf::from(required_variable(&document.variables, "CARGO_HOME")?);
        let path_prefixes = validate_path_prefixes(
            &toolchain_root,
            document.path_prefixes,
            [
                &cargo_home.join("bin"),
                compiler.parent().unwrap(),
                linker.parent().unwrap(),
            ],
        )?;
        Ok(Self {
            cargo,
            variables: document.variables,
            path_prefixes,
        })
    }

    pub(crate) fn cargo_command(&self) -> Result<Command, String> {
        let mut command = Command::new(&self.cargo);
        for (name, value) in &self.variables {
            match value {
                Some(value) => {
                    command.env(name, value);
                }
                None => {
                    command.env_remove(name);
                }
            }
        }
        let inherited = env::var_os("PATH").unwrap_or_default();
        let paths = self
            .path_prefixes
            .iter()
            .cloned()
            .chain(env::split_paths(&inherited));
        let path = env::join_paths(paths)
            .map_err(|error| format!("cannot compose Bootstrap builder PATH: {error}"))?;
        command.env("PATH", path);
        Ok(command)
    }
}

fn validate_variables(
    variables: &BTreeMap<String, Option<String>>,
    toolchain_root: &Path,
) -> Result<(), String> {
    let expected = ENVIRONMENT_VARIABLES.into_iter().collect::<BTreeSet<_>>();
    let actual = variables
        .keys()
        .map(String::as_str)
        .collect::<BTreeSet<_>>();
    if actual != expected {
        return Err("Bootstrap builder environment variable set is invalid".to_owned());
    }
    for name in [
        "CARGO_HOME",
        "RUSTUP_HOME",
        "UniversalCRTSdkDir",
        "VCINSTALLDIR",
        "VCToolsInstallDir",
        "WindowsSdkBinPath",
        "WindowsSdkDir",
        "WindowsSdkVerBinPath",
    ] {
        validate_controlled_directory(
            toolchain_root,
            required_variable(variables, name)?,
            &format!("Bootstrap {name}"),
        )?;
    }
    for name in ["INCLUDE", "LIB"] {
        let value = required_variable(variables, name)?;
        if value.is_empty() {
            return Err(format!("Bootstrap {name} cannot be empty"));
        }
        for path in value.split(';') {
            validate_controlled_directory(toolchain_root, path, &format!("Bootstrap {name} path"))?;
        }
    }
    Ok(())
}

fn required_variable<'a>(
    variables: &'a BTreeMap<String, Option<String>>,
    name: &str,
) -> Result<&'a str, String> {
    variables
        .get(name)
        .and_then(Option::as_deref)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("Bootstrap builder environment is missing {name}"))
}

fn validate_path_prefixes(
    toolchain_root: &Path,
    paths: Vec<PathBuf>,
    required_paths: [&Path; 3],
) -> Result<Vec<PathBuf>, String> {
    if paths.is_empty() || paths.len() > 16 {
        return Err("Bootstrap builder PATH prefix set is invalid".to_owned());
    }
    let mut unique = BTreeSet::new();
    for path in &paths {
        validate_controlled_directory(
            toolchain_root,
            path.to_string_lossy().as_ref(),
            "Bootstrap PATH prefix",
        )?;
        if !unique.insert(path.to_string_lossy().to_ascii_lowercase()) {
            return Err(format!(
                "Bootstrap builder PATH repeats '{}'",
                path.display()
            ));
        }
    }
    for required in required_paths {
        if !paths.iter().any(|path| path == required) {
            return Err(format!(
                "Bootstrap builder PATH does not contain '{}'",
                required.display()
            ));
        }
    }
    Ok(paths)
}

fn validate_controlled_directory(root: &Path, value: &str, label: &str) -> Result<PathBuf, String> {
    let path = PathBuf::from(value);
    validate_descendant_parent(root, &path, label, true)?;
    regular_directory(&path, label)?;
    Ok(path)
}

fn validate_tool(
    root: &Path,
    artifact: &ToolArtifact,
    expected_name: &str,
    label: &str,
) -> Result<PathBuf, String> {
    if artifact.path.file_name().and_then(|name| name.to_str()) != Some(expected_name)
        || artifact.length == 0
        || artifact.length > MAX_TOOL_BYTES
        || !is_sha256(&artifact.sha256)
    {
        return Err(format!("{label} record is invalid"));
    }
    validate_descendant_parent(root, &artifact.path, label, false)?;
    let bytes = read_regular_file(&artifact.path, label, MAX_TOOL_BYTES)?;
    if bytes.len() as u64 != artifact.length || sha256_hex(&bytes) != artifact.sha256 {
        return Err(format!("{label} integrity does not match its record"));
    }
    Ok(artifact.path.clone())
}

fn validate_descendant_parent(
    root: &Path,
    path: &Path,
    label: &str,
    include_leaf: bool,
) -> Result<(), String> {
    if !path.is_absolute() {
        return Err(format!("{label} must be absolute: {}", path.display()));
    }
    let relative = path
        .strip_prefix(root)
        .map_err(|_| format!("{label} escaped Bootstrap toolchains: {}", path.display()))?;
    let checked = if include_leaf {
        relative
    } else {
        relative
            .parent()
            .ok_or_else(|| format!("{label} has no controlled parent"))?
    };
    let mut current = root.to_path_buf();
    for component in checked.components() {
        let Component::Normal(segment) = component else {
            return Err(format!("{label} has an unsafe path: {}", path.display()));
        };
        current.push(segment);
        regular_directory(&current, label)?;
    }
    Ok(())
}

fn valid_environment_revision(value: &str) -> bool {
    value.len() == 16
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(crate = "serde", deny_unknown_fields, rename_all = "camelCase")]
struct BootstrapContract {
    schema: String,
    rust_toolchain: String,
    msvc_channel: String,
}

#[derive(Deserialize)]
#[serde(crate = "serde", deny_unknown_fields, rename_all = "camelCase")]
struct EnvironmentDocument {
    schema: String,
    contract: BootstrapContract,
    contract_revision: String,
    environment_revision: String,
    variables: BTreeMap<String, Option<String>>,
    path_prefixes: Vec<PathBuf>,
    tools: ToolSet,
}

#[derive(Deserialize)]
#[serde(crate = "serde", deny_unknown_fields)]
struct ToolSet {
    cargo: ToolArtifact,
    rustc: ToolArtifact,
    compiler: ToolArtifact,
    linker: ToolArtifact,
}

#[derive(Deserialize)]
#[serde(crate = "serde", deny_unknown_fields)]
struct ToolArtifact {
    path: PathBuf,
    length: u64,
    sha256: String,
}

#[cfg(test)]
mod tests;
