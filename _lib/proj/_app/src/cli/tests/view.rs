use std::fs;

use super::*;

#[test]
fn view_source_resolves_a_static_collection_through_the_read_only_cli_path() {
    let fixture = Fixture::new();
    fixture.core_command(".view/source", "meta.view.source");
    let group = fixture.resource(".group");
    fixture.resource(".group/child");
    let view = group.join("subcommands/view");
    fs::create_dir_all(&view).unwrap();
    fs::write(
        view.join("web.json"),
        r#"{
          "schema":"swawkit.view-source/web/v1",
          "column":{
            "width":"normal",
            "body":{"component":"resource-list","source":"facet-result"}
          }
        }"#,
    )
    .unwrap();
    fixture.initialize();

    let exit_code = run(
        &fixture.context,
        &argv(&[".view/source", "$/system::group/subcommands"]),
        CommandProcessMode::InheritConsole,
    )
    .unwrap();

    assert_eq!(exit_code, 0);
}
