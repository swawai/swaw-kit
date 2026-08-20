use std::path::{Component, Path, PathBuf};

use swawkit_proj_protocol::{
    DEV_ENVIRONMENT_EXPORT_NAME, DevEnvironmentExport, parse_dev_environment,
};

use super::{EnvironmentPlan, MAX_ENVIRONMENT_SCRIPT_BYTES, absolute_normalized};
use crate::development::setup::PUBLICATION_TOKEN_VARIABLE;
use crate::development::setup::provider::read_ready;
use crate::development::setup::storage::{
    existing_directory_chain, read_replaceable_bounded, regular_directory, regular_file_length,
};

const MAX_ENVIRONMENT_EXPORT_BYTES: u64 = 1024 * 1024;

pub fn verify_ready_export(data_root: &Path, expected_input_revision: &str) -> Result<(), String> {
    let state_before = read_ready(data_root, expected_input_revision).map_err(|_| {
        "The .dev/setup Provider State is missing, invalid, or outdated.".to_owned()
    })?;
    let export_root = existing_directory_chain(
        data_root,
        &["modules", "system", "dev", "setup", "export"],
        "development environment export",
    )
    .map_err(|_| "The development environment export directory is missing or unsafe.".to_owned())?;
    let document_content = read_replaceable_bounded(
        &export_root.join(DEV_ENVIRONMENT_EXPORT_NAME),
        "Dev environment Export",
        MAX_ENVIRONMENT_EXPORT_BYTES,
    )
    .map_err(|_| "The environment.json Export is missing, unsafe, or too large.".to_owned())?;
    let document = parse_dev_environment(&document_content)
        .map_err(|_| "The environment.json Export does not satisfy its schema.".to_owned())?;
    if document.input_revision != state_before.input_revision()
        || document.publication_token != state_before.token()
    {
        return Err(
            "The environment.json Export does not match the current Provider publication."
                .to_owned(),
        );
    }
    if !document.variables.iter().any(|variable| {
        variable.name == PUBLICATION_TOKEN_VARIABLE
            && variable.value.as_deref() == Some(state_before.token())
    }) {
        return Err(
            "The environment.json Export does not bind the current publication token.".to_owned(),
        );
    }

    let plan = plan_from_document(&document)?;
    let scripts = plan.render();
    require_exact_file(
        &export_root.join("env.cmd"),
        scripts.cmd().as_bytes(),
        "env.cmd",
    )?;
    let mut expected_ps1 = vec![0xef, 0xbb, 0xbf];
    expected_ps1.extend_from_slice(scripts.ps1().as_bytes());
    require_exact_file(&export_root.join("env.ps1"), &expected_ps1, "env.ps1")?;

    for path in &plan.paths {
        verify_path_directory(path)?;
    }
    verify_executable(document.bun_executable.as_deref(), "bun.exe", "Bun")?;
    verify_executable(
        document.pwsh_executable.as_deref(),
        "pwsh.exe",
        "PowerShell",
    )?;

    let state_after = read_ready(data_root, expected_input_revision).map_err(|_| {
        "The .dev/setup Provider State changed while the Export was being checked.".to_owned()
    })?;
    if state_before != state_after {
        return Err(
            "The .dev/setup Provider publication changed while it was being checked.".to_owned(),
        );
    }
    Ok(())
}

fn plan_from_document(document: &DevEnvironmentExport) -> Result<EnvironmentPlan, String> {
    let paths = document
        .paths
        .iter()
        .map(|value| {
            let path = PathBuf::from(value);
            let normalized = absolute_normalized(path.clone()).map_err(|_| {
                "The environment.json Export contains a non-canonical PATH entry.".to_owned()
            })?;
            if path != normalized {
                return Err(
                    "The environment.json Export contains a non-canonical PATH entry.".to_owned(),
                );
            }
            Ok(path)
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok(EnvironmentPlan {
        variables: document
            .variables
            .iter()
            .map(|variable| (variable.name.clone(), variable.value.clone()))
            .collect(),
        paths,
    })
}

fn require_exact_file(path: &Path, expected: &[u8], name: &str) -> Result<(), String> {
    let actual = read_replaceable_bounded(path, name, MAX_ENVIRONMENT_SCRIPT_BYTES)
        .map_err(|_| format!("The {name} Export is missing, unsafe, or too large."))?;
    if actual == expected {
        Ok(())
    } else {
        Err(format!(
            "The {name} Export does not match environment.json."
        ))
    }
}

fn verify_path_directory(path: &Path) -> Result<(), String> {
    verify_absolute_directory_chain(path, "Dev environment PATH entry").map_err(|_| {
        "A declared development environment PATH entry is missing or unsafe.".to_owned()
    })
}

fn verify_absolute_directory_chain(path: &Path, subject: &str) -> Result<(), String> {
    let mut current = PathBuf::new();
    let mut rooted = false;
    for component in path.components() {
        match component {
            Component::Prefix(_) if current.as_os_str().is_empty() => {
                current.push(component.as_os_str());
            }
            Component::RootDir if !rooted => {
                current.push(component.as_os_str());
                rooted = true;
                regular_directory(&current, subject).map_err(|error| error.to_string())?;
            }
            Component::Normal(segment) if rooted => {
                current.push(segment);
                regular_directory(&current, subject).map_err(|error| error.to_string())?;
            }
            _ => return Err(format!("{subject} is not a canonical absolute path")),
        }
    }
    if rooted {
        Ok(())
    } else {
        Err(format!("{subject} is not a canonical absolute path"))
    }
}

fn verify_executable(value: Option<&str>, expected_name: &str, label: &str) -> Result<(), String> {
    let Some(value) = value else {
        return Ok(());
    };
    let path = Path::new(value);
    let parent_is_safe = path
        .parent()
        .is_some_and(|parent| verify_absolute_directory_chain(parent, label).is_ok());
    if !path
        .file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name.eq_ignore_ascii_case(expected_name))
        || !parent_is_safe
        || !regular_file_length(path, "Dev environment executable").is_ok_and(|length| length > 0)
    {
        return Err(format!(
            "The declared {label} executable is missing or unsafe."
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::sync::atomic::{AtomicU64, Ordering};

    use sha2::{Digest, Sha256};

    use super::*;
    use crate::development::setup::provider::SetupProvider;

    static NEXT: AtomicU64 = AtomicU64::new(0);

    #[test]
    fn verification_covers_state_document_scripts_and_paths() {
        let fixture = ReadyFixture::new();

        verify_ready_export(&fixture.data_root, &fixture.input_revision).unwrap();

        fs::write(fixture.export_root.join("env.cmd"), b"stale\r\n").unwrap();
        let error = verify_ready_export(&fixture.data_root, &fixture.input_revision).unwrap_err();
        assert!(error.contains("env.cmd"));
    }

    #[test]
    fn verification_rejects_missing_declared_paths() {
        let fixture = ReadyFixture::new();
        fs::remove_dir_all(&fixture.path_entry).unwrap();

        let error = verify_ready_export(&fixture.data_root, &fixture.input_revision).unwrap_err();
        assert!(error.contains("PATH entry"));
    }

    #[test]
    fn absolute_directory_walk_rejects_a_reparse_ancestor() {
        let fixture = ReadyFixture::new();
        let external = fixture.root.join("external");
        let external_bin = external.join("bin");
        fs::create_dir_all(&external_bin).unwrap();
        let link = fixture.root.join("linked");
        if let Err(error) = std::os::windows::fs::symlink_dir(&external, &link) {
            eprintln!("skipping directory reparse test: {error}");
            return;
        }

        let error = verify_absolute_directory_chain(&link.join("bin"), "fixture").unwrap_err();

        assert!(error.contains("regular filesystem entry"), "{error}");
        fs::remove_dir(link).unwrap();
    }

    struct ReadyFixture {
        root: PathBuf,
        data_root: PathBuf,
        export_root: PathBuf,
        path_entry: PathBuf,
        input_revision: String,
    }

    impl ReadyFixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "swawkit-ready-environment-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            let data_root = root.join("data/proj.fixture");
            fs::create_dir_all(&data_root).unwrap();
            let profile_content = b"{}\r\n";
            fs::write(data_root.join("_profile.json"), profile_content).unwrap();
            let profile_revision = format!("sha256-{:x}", Sha256::digest(profile_content));
            let input_revision = format!("sha256-{}", "a".repeat(64));
            let provider =
                SetupProvider::new(&data_root, profile_revision, input_revision.clone()).unwrap();
            let publication = provider.start().unwrap();
            let path_entry = data_root.join("modules/system/dev/setup/export/tool/bin");
            fs::create_dir_all(&path_entry).unwrap();
            let mut plan = EnvironmentPlan::default();
            plan.prepend_path(&path_entry).unwrap();
            plan.set(
                PUBLICATION_TOKEN_VARIABLE,
                Some(publication.token().to_owned()),
            )
            .unwrap();
            plan.render().publish(&data_root).unwrap();
            plan.publish_export(
                &data_root,
                publication.input_revision(),
                publication.token(),
                None,
                None,
            )
            .unwrap();
            provider.complete(&publication).unwrap();
            let export_root = data_root.join("modules/system/dev/setup/export");
            Self {
                root,
                data_root,
                export_root,
                path_entry,
                input_revision,
            }
        }
    }

    impl Drop for ReadyFixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }
}
