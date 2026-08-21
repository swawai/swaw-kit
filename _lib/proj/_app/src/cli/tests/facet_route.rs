use super::*;

#[test]
fn canonical_execute_route_runs_and_journals_the_backing_command() {
    let fixture = Fixture::new();
    fixture.command(".group/tool", "run.cmd", "@echo off\r\nexit /b 17\r\n");
    fixture.bind();

    let exit_code = run(
        &fixture.context,
        &argv(&["$/system::group/subcommands::tool/execute"]),
        CommandProcessMode::InheritConsole,
    )
    .unwrap();

    assert_eq!(exit_code, 17);
    let catalog = CatalogSnapshot::discover(&fixture.context, None).unwrap();
    let runs = swawkit_proj::command_journal::CommandJournalAccess::resolve(
        &fixture.data_root(),
        &catalog,
        swawkit_proj::command_journal::CommandLocator::from_cli_target(&catalog, ".group/tool")
            .unwrap(),
    )
    .unwrap()
    .runs()
    .unwrap();
    assert_eq!(runs.len(), 1);
    assert_eq!(runs[0].source, "CLI");
}
