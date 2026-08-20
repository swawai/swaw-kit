use super::*;

fn system_delegate_manifest(owner: &str) -> String {
    format!(
        r#"{{"schema":"swawkit.command-module/v12","execution":{{"type":"delegate","owner":{{"type":"command","space":"system","address":"{owner}"}}}}}}"#
    )
}

#[test]
fn system_native_owner_and_delegate_use_the_same_execution_model() {
    let fixture = Fixture::new();
    fixture.file(
        &fixture.system,
        "context/swawkit.module.json",
        native_manifest(),
    );
    fixture.file(
        &fixture.system,
        "context/add/swawkit.module.json",
        &system_delegate_manifest(".context"),
    );

    let snapshot = fixture.discover();
    let owner = node(&snapshot, ".context");
    assert!(owner.runnable, "{:?}", owner.diagnostic);
    assert_eq!(owner.adapter.as_deref(), Some("native"));
    assert_eq!(owner.native_owner.as_deref(), Some(".context"));
    let port = node(&snapshot, ".context/add");
    assert!(port.runnable, "{:?}", port.diagnostic);
    assert_eq!(port.adapter.as_deref(), Some("delegate"));
    assert_eq!(port.native_owner.as_deref(), Some(".context"));
}

#[test]
fn delegate_cannot_cross_command_spaces() {
    let fixture = Fixture::new();
    fixture.file(
        &fixture.system,
        "context/swawkit.module.json",
        native_manifest(),
    );
    fixture.file(
        &fixture.system,
        "context/add/swawkit.module.json",
        &delegate_manifest("swaw/domain"),
    );
    fixture.file(
        &fixture.swaw,
        "domain/swawkit.module.json",
        native_manifest(),
    );

    let snapshot = fixture.discover();
    let command = node(&snapshot, ".context/add");
    assert!(!command.runnable);
    assert!(
        command
            .diagnostic
            .as_deref()
            .is_some_and(|message| message.contains("space and namespace")),
        "{:?}",
        command.diagnostic
    );
}

#[test]
fn system_delegate_cannot_cross_a_nested_native_owner() {
    let fixture = Fixture::new();
    fixture.file(
        &fixture.system,
        "context/swawkit.module.json",
        native_manifest(),
    );
    fixture.file(
        &fixture.system,
        "context/admin/swawkit.module.json",
        native_manifest(),
    );
    fixture.file(
        &fixture.system,
        "context/admin/add/swawkit.module.json",
        &system_delegate_manifest(".context"),
    );

    let snapshot = fixture.discover();
    let command = node(&snapshot, ".context/admin/add");
    assert!(!command.runnable);
    assert!(
        command
            .diagnostic
            .as_deref()
            .is_some_and(|message| message.contains("cannot cross nested native owner")),
        "{:?}",
        command.diagnostic
    );
}
