use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use swawkit_proj_protocol::serde::{self, Serialize};
use swawkit_proj_protocol::{revision, serde_json, sha256_hex};

use super::{BuilderEnvironment, ENVIRONMENT_SCHEMA, ENVIRONMENT_VARIABLES};
use crate::filesystem::unique_token;

struct Fixture {
    root: PathBuf,
    contract: Vec<u8>,
    cargo: PathBuf,
    document: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let root =
            std::env::temp_dir().join(format!("swawkit-builder-environment-{}", unique_token()));
        let proj = root.join("_lib/proj");
        let bootstrap = root.join("data/proj_cache/bootstrap");
        let toolchains = bootstrap.join("toolchains");
        let cargo_home = toolchains.join("rust/cargo");
        let rust_bin = toolchains.join("rust/toolchain/bin");
        let msvc_bin = toolchains.join("msvc/bin");
        let sdk = toolchains.join("msvc/sdk");
        let include = toolchains.join("msvc/include");
        let lib = toolchains.join("msvc/lib");
        for path in [
            &proj,
            &cargo_home.join("bin"),
            &rust_bin,
            &msvc_bin,
            &sdk,
            &include,
            &lib,
        ] {
            fs::create_dir_all(path).unwrap();
        }

        let contract = br#"{"schema":"swawkit.proj-bootstrap/v2","rustToolchain":"fixture","msvcChannel":"fixture","commandRuntime":{"bunVersion":"1.2.15","bunSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","pwshVersion":"7.6.4","pwshSha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}"#.to_vec();
        fs::write(proj.join("bootstrap.json"), &contract).unwrap();
        let cargo = tool(&rust_bin, "cargo.exe", b"cargo");
        let rustc = tool(&rust_bin, "rustc.exe", b"rustc");
        let compiler = tool(&msvc_bin, "cl.exe", b"compiler");
        let linker = tool(&msvc_bin, "link.exe", b"linker");
        let mut variables = ENVIRONMENT_VARIABLES
            .into_iter()
            .map(|name| (name.to_owned(), Some(String::new())))
            .collect::<BTreeMap<_, _>>();
        for name in [
            "UniversalCRTSdkDir",
            "VCINSTALLDIR",
            "VCToolsInstallDir",
            "WindowsSdkBinPath",
            "WindowsSdkDir",
            "WindowsSdkVerBinPath",
        ] {
            variables.insert(name.to_owned(), Some(text(&sdk)));
        }
        variables.insert("CARGO_HOME".to_owned(), Some(text(&cargo_home)));
        variables.insert(
            "RUSTUP_HOME".to_owned(),
            Some(text(&toolchains.join("rust"))),
        );
        variables.insert("INCLUDE".to_owned(), Some(text(&include)));
        variables.insert("LIB".to_owned(), Some(text(&lib)));
        variables.insert("RUSTC".to_owned(), Some(text(&rustc.path)));
        variables.insert("CARGO_BUILD_RUSTC".to_owned(), Some(text(&rustc.path)));

        let document = bootstrap.join("environment.json");
        fs::write(
            &document,
            serde_json::to_vec_pretty(&serde_json::json!({
                "schema": ENVIRONMENT_SCHEMA,
                "contract": {
                    "schema": "swawkit.proj-bootstrap/v2",
                    "rustToolchain": "fixture",
                    "msvcChannel": "fixture",
                    "commandRuntime": {
                        "bunVersion": "1.2.15",
                        "bunSha256": "a".repeat(64),
                        "pwshVersion": "7.6.4",
                        "pwshSha256": "b".repeat(64)
                    }
                },
                "contractRevision": revision(&contract),
                "environmentRevision": "0123456789abcdef",
                "variables": variables,
                "pathPrefixes": [cargo_home.join("bin"), &msvc_bin],
                "tools": {
                    "cargo": cargo,
                    "rustc": rustc,
                    "compiler": compiler,
                    "linker": linker
                }
            }))
            .unwrap(),
        )
        .unwrap();

        Self {
            root,
            contract,
            cargo: rust_bin.join("cargo.exe"),
            document,
        }
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[derive(Serialize)]
#[serde(crate = "serde")]
struct Artifact {
    path: PathBuf,
    length: u64,
    sha256: String,
}

fn tool(root: &Path, name: &str, bytes: &[u8]) -> Artifact {
    let path = root.join(name);
    fs::write(&path, bytes).unwrap();
    Artifact {
        path,
        length: bytes.len() as u64,
        sha256: sha256_hex(bytes),
    }
}

fn text(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

#[test]
fn exact_bootstrap_projection_loads_without_a_dev_publication() {
    let fixture = Fixture::new();
    let builder = BuilderEnvironment::load(&fixture.root).unwrap();
    assert_eq!(builder.cargo, fixture.cargo);
    assert!(builder.cargo_command().is_ok());
}

#[test]
fn changed_bootstrap_contract_invalidates_the_projection() {
    let fixture = Fixture::new();
    let mut changed = fixture.contract.clone();
    changed.push(b' ');
    fs::write(fixture.root.join("_lib/proj/bootstrap.json"), changed).unwrap();

    let error = BuilderEnvironment::load(&fixture.root).err().unwrap();
    assert!(error.contains("does not match bootstrap.json"), "{error}");
    assert!(error.contains("_bootstrap\\setup.ps1"), "{error}");
}

#[test]
fn changed_tool_bytes_invalidate_the_projection() {
    let fixture = Fixture::new();
    fs::write(&fixture.cargo, b"Cargo").unwrap();

    let error = BuilderEnvironment::load(&fixture.root).err().unwrap();
    assert!(error.contains("integrity does not match"), "{error}");
}

#[test]
fn missing_projection_has_one_explicit_repair_path() {
    let fixture = Fixture::new();
    fs::remove_file(&fixture.document).unwrap();

    let error = BuilderEnvironment::load(&fixture.root).err().unwrap();
    assert!(error.contains("_bootstrap\\setup.ps1"), "{error}");
}
