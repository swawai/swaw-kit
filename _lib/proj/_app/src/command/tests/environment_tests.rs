use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsStr;
use std::path::PathBuf;

use crate::launch::{ENTRY_FILE_ENV, LAUNCH_MODE_ENV};
use swawkit_proj_protocol::COMMAND_ENVIRONMENT_PROTOCOL;

use super::*;
use crate::command::environment::{
    CONDITIONAL_PROJECT_ENVIRONMENT, RETIRED_COMMAND_ENVIRONMENT, catalog_module_roots,
};

#[test]
fn process_environment_is_declarative() {
    let fixture = Fixture::new();
    fixture.command(".tool", "exit 0");
    let command = ResolvedCommand::from_catalog(&fixture.catalog(), ".tool").unwrap();
    let context = fixture.context();

    let mut run =
        ProcessEnvironment::for_command(&context, &command).expect("build run environment");
    assert_eq!(
        run.value("SWAWKIT_PROJ_CORE_COMMAND_PROTOCOL"),
        Some(Some(OsStr::new(COMMAND_ENVIRONMENT_PROTOCOL)))
    );
    assert_eq!(
        run.value("SWAWKIT_PROJ_CORE_COMMAND_EVENT_PROTOCOL"),
        Some(Some(OsStr::new("swawkit.command-event-frame/v1")))
    );
    assert_eq!(run.value(ENTRY_FILE_ENV), Some(None));
    assert_eq!(run.value(LAUNCH_MODE_ENV), Some(None));
    assert_eq!(run.value("SWAWKIT_PROJ_CORE_COMMAND_PHASE"), Some(None));
    assert_eq!(
        run.value("SWAWKIT_PROJ_CORE_COMMAND_GUARD_SCOPE"),
        Some(None)
    );
    assert_eq!(
        run.value("SWAWKIT_PROJ_CORE_COMMAND_ENTRY_FILE"),
        Some(Some(context.entry_file.as_os_str()))
    );
    assert_eq!(
        run.value("SWAWKIT_PROJ_CORE_DEV_EXECUTABLE"),
        Some(Some(context.dev_executable.as_os_str()))
    );
    assert_eq!(
        RETIRED_COMMAND_ENVIRONMENT,
        EXPECTED_RETIRED_COMMAND_ENVIRONMENT
    );
    assert_eq!(
        CONDITIONAL_PROJECT_ENVIRONMENT,
        EXPECTED_CONDITIONAL_PROJECT_ENVIRONMENT
    );
    let cleared_names = RETIRED_COMMAND_ENVIRONMENT
        .iter()
        .chain(CONDITIONAL_PROJECT_ENVIRONMENT.iter())
        .copied()
        .collect::<Vec<_>>();
    assert_eq!(
        cleared_names.iter().copied().collect::<BTreeSet<_>>().len(),
        cleared_names.len(),
        "environment cleanup registry must not contain duplicate names"
    );
    for name in EXPECTED_RETIRED_COMMAND_ENVIRONMENT {
        assert_eq!(run.value(name), Some(None), "{name} must be removed");
    }
    assert_eq!(
        run.value("SWAWKIT_PROJ_CORE_COMMAND_ADDRESS"),
        Some(Some(OsStr::new(".tool")))
    );
    assert_eq!(
        run.value("SWAWKIT_PROJ_CORE_COMMAND_DATA_ROOT"),
        Some(Some(
            fixture
                .data_root
                .join("modules")
                .join("system")
                .join("tool")
                .as_os_str()
        ))
    );
    assert_eq!(run.value("SWAWKIT_PROJ_PROJECT_ROOT"), Some(None));
    assert_eq!(
        run.value("SWAWKIT_PROJ_SYSTEM_ROOT"),
        Some(Some(fixture.system_root.as_os_str()))
    );
    assert_eq!(run.value("SWAWKIT_PROJ_PROJECT_MODULE_ROOT"), Some(None));
    let module_roots: BTreeMap<String, PathBuf> = serde_json::from_str(
        run.value("SWAWKIT_PROJ_MODULE_ROOTS")
            .flatten()
            .and_then(OsStr::to_str)
            .expect("fixed Module root projection"),
    )
    .expect("parse fixed Module root projection");
    assert_eq!(
        module_roots,
        BTreeMap::from([
            ("project".to_owned(), fixture.project_module_root.clone()),
            ("swaw".to_owned(), fixture.swaw_module_root.clone()),
        ])
    );
    assert_eq!(
        run.value("SWAWKIT_HOME"),
        Some(Some(fixture.root.as_os_str()))
    );
    assert_eq!(
        run.value("SWAWKIT_PROJ_LANGUAGE"),
        Some(Some(OsStr::new("zh-CN")))
    );
    for name in [
        "SWAWKIT_PROJ_CORE_COMMAND_OWNER_ADDRESS",
        "SWAWKIT_PROJ_CORE_COMMAND_OWNER_DIR",
        "SWAWKIT_PROJ_CORE_COMMAND_OWNER_DATA_ROOT",
    ] {
        assert_eq!(run.value(name), Some(None));
    }
    let owner_data_root = fixture.data_root.join("modules/swaw/owner");
    run.apply_native_owner("swaw/owner", &fixture.swaw_module_root, &owner_data_root);
    assert_eq!(
        run.value("SWAWKIT_PROJ_CORE_COMMAND_OWNER_ADDRESS"),
        Some(Some(OsStr::new("swaw/owner")))
    );
    assert_eq!(
        run.value("SWAWKIT_PROJ_CORE_COMMAND_OWNER_DIR"),
        Some(Some(fixture.swaw_module_root.as_os_str()))
    );
    assert_eq!(
        run.value("SWAWKIT_PROJ_CORE_COMMAND_OWNER_DATA_ROOT"),
        Some(Some(owner_data_root.as_os_str()))
    );
}

#[test]
fn execution_context_omits_an_unsafe_project_module_root() {
    let fixture = Fixture::new();
    fs::remove_dir_all(&fixture.project_module_root).expect("remove regular project Module root");
    let external = fixture.root.join("external-project-modules");
    fs::create_dir_all(&external).expect("create external project Module root");
    if std::os::windows::fs::symlink_dir(&external, &fixture.project_module_root).is_err() {
        return;
    }
    let catalog = fixture.catalog();
    let roots = catalog_module_roots(&catalog);

    assert_eq!(
        roots.get("swaw").map(PathBuf::as_path),
        Some(fixture.swaw_module_root.as_path())
    );
    assert!(!roots.contains_key("project"));
    fs::remove_dir(&fixture.project_module_root).expect("remove project Module root reparse point");
}
