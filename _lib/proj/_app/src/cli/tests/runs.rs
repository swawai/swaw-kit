use super::*;

#[test]
fn runs_read_history_and_latest_after_the_target_stops_being_runnable() {
    let fixture = Fixture::new();
    let runs_directory = fixture.context.system_root().join("runs");
    copy_tree(
        &Path::new(env!("CARGO_MANIFEST_DIR")).join("../system/runs"),
        &runs_directory,
    );
    let command_directory = fixture.command(
        ".demo",
        "run.cmd",
        "@echo off\r\necho journal fixture\r\nexit /b 0\r\n",
    );
    fixture.bind();

    for _ in 0..3 {
        assert_eq!(
            run(
                &fixture.context,
                &argv(&[".demo"]),
                CommandProcessMode::InheritConsole,
            )
            .unwrap(),
            0
        );
    }
    let runs_root = fixture.data_root().join("modules/system/demo/_runs");
    let run_id = fs::read_dir(&runs_root)
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .file_name()
        .to_string_lossy()
        .into_owned();
    fs::remove_file(command_directory.join("execute/run.cmd")).unwrap();

    for arguments in [
        vec![".runs"],
        vec![".runs", "--json"],
        vec![".runs", "--json", "$/system::demo"],
        vec![".runs", "--run", &run_id],
        vec![".runs", ".demo"],
        vec![".runs", ".demo", "--latest", "1"],
        vec![".runs", ".demo", "--latest", "1..3"],
        vec![".runs", ".demo", "--run", &run_id, "--after", "0"],
    ] {
        assert_eq!(
            run(
                &fixture.context,
                &argv(&arguments),
                CommandProcessMode::InheritConsole,
            )
            .unwrap(),
            0
        );
    }

    let missing = run(
        &fixture.context,
        &argv(&[".runs", ".missing"]),
        CommandProcessMode::InheritConsole,
    )
    .unwrap_err();
    assert!(missing.to_string().contains("command not found"));

    let removed = run(
        &fixture.context,
        &argv(&[".logs"]),
        CommandProcessMode::InheritConsole,
    )
    .unwrap_err();
    assert!(removed.to_string().contains("command not found: .logs"));
}

fn copy_tree(source: &Path, target: &Path) {
    fs::create_dir_all(target).expect("create Runs fixture directory");
    for entry in fs::read_dir(source).expect("read Runs fixture source") {
        let entry = entry.expect("read Runs fixture entry");
        let target = target.join(entry.file_name());
        if entry.file_type().expect("read Runs fixture type").is_dir() {
            copy_tree(&entry.path(), &target);
        } else {
            fs::copy(entry.path(), target).expect("copy Runs fixture file");
        }
    }
}
