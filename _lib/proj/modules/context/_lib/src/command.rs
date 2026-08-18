use std::ffi::{OsStr, OsString};
use std::io::{self, Read, Write};
use std::process::ExitCode;

use serde::Serialize;

use crate::address::command_reference;
use crate::error::{ContextError, ContextResult};
use crate::model::{ContextRecord, MAX_NOTE_BYTES, MAX_PROMPT_BYTES, validate_text};
use crate::projection::{render_markdown, subject_collection};
use crate::runtime::ContextRuntime;

const COMMAND_ADDRESS_ENV: &str = "SWAWKIT_PROJ_CORE_COMMAND_ADDRESS";
const DESCRIPTION_PROTOCOL: &str = "swawkit.native-command-description/v1";
const DESCRIPTION_ARGUMENT: &str = "--swawkit-describe";
const OWNER_ADDRESS: &str = "swaw/context";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Command {
    New,
    Add,
    Remove,
    Note,
    Prompt,
    Show,
    Render,
    List,
    Delete,
}

const COMMANDS: &[(Command, &str)] = &[
    (Command::New, "swaw/context/new"),
    (Command::Add, "swaw/context/add"),
    (Command::Remove, "swaw/context/remove"),
    (Command::Note, "swaw/context/note"),
    (Command::Prompt, "swaw/context/prompt"),
    (Command::Show, "swaw/context/show"),
    (Command::Render, "swaw/context/render"),
    (Command::List, "swaw/context/list"),
    (Command::Delete, "swaw/context/delete"),
];

impl Command {
    fn from_address(address: &str) -> ContextResult<Self> {
        COMMANDS
            .iter()
            .find_map(|(command, registered)| (*registered == address).then_some(*command))
            .ok_or_else(|| match address {
                OWNER_ADDRESS => ContextError::new(
                    "swaw/context is a native module owner; invoke one of its child commands",
                ),
                _ => ContextError::new(format!("unsupported Context command address: {address}")),
            })
    }

    fn address(self) -> &'static str {
        COMMANDS
            .iter()
            .find_map(|(command, address)| (*command == self).then_some(*address))
            .expect("every Context command belongs to the registry")
    }
}

#[derive(Serialize)]
struct NativeDescription<'a> {
    schema: &'static str,
    owner: &'static str,
    commands: Vec<&'a str>,
}

pub fn run() -> ExitCode {
    let arguments = std::env::args_os().skip(1).collect::<Vec<_>>();
    let result = if matches!(arguments.as_slice(), [argument] if argument == DESCRIPTION_ARGUMENT) {
        describe()
    } else {
        std::env::var(COMMAND_ADDRESS_ENV)
            .map_err(|_| {
                ContextError::new(format!("missing command environment {COMMAND_ADDRESS_ENV}"))
            })
            .and_then(|address| Command::from_address(&address))
            .and_then(|command| execute(command, arguments))
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{error}");
            ExitCode::FAILURE
        }
    }
}

fn describe() -> ContextResult<()> {
    write_json(&NativeDescription {
        schema: DESCRIPTION_PROTOCOL,
        owner: OWNER_ADDRESS,
        commands: COMMANDS.iter().map(|(_, address)| *address).collect(),
    })
}

fn execute(command: Command, arguments: Vec<OsString>) -> ContextResult<()> {
    let runtime = ContextRuntime::from_environment()?;
    let address = command.address();
    match command {
        Command::New => create(address, &arguments, &runtime),
        Command::Add => add(address, &arguments, &runtime),
        Command::Remove => remove(address, &arguments, &runtime),
        Command::Note => note(address, &arguments, &runtime, &mut io::stdin().lock()),
        Command::Prompt => prompt(address, &arguments, &runtime, &mut io::stdin().lock()),
        Command::Show => show(address, &arguments, &runtime),
        Command::Render => render(address, &arguments, &runtime),
        Command::List => list(address, &arguments, &runtime),
        Command::Delete => delete(address, &arguments, &runtime),
    }
}

fn create(address: &str, arguments: &[OsString], runtime: &ContextRuntime) -> ContextResult<()> {
    let [id] = arguments else {
        return Err(usage(address, "<context-id>"));
    };
    let id = unicode(id, "Context ID")?;
    runtime.store.create(id)?;
    write_message(&format!("Context created: {id}"))
}

fn add(address: &str, arguments: &[OsString], runtime: &ContextRuntime) -> ContextResult<()> {
    let Some((id, targets)) = arguments
        .split_first()
        .filter(|(_, targets)| !targets.is_empty())
    else {
        return Err(usage(address, "<context-id> <command-address>..."));
    };
    let id = unicode(id, "Context ID")?;
    let commands = targets
        .iter()
        .map(|target| {
            let target = unicode(target, "command address")?;
            command_reference(target)
        })
        .collect::<ContextResult<Vec<_>>>()?;
    let record = runtime.store.add_commands(id, commands)?;
    write_updated(&record)
}

fn remove(address: &str, arguments: &[OsString], runtime: &ContextRuntime) -> ContextResult<()> {
    let Some((id, targets)) = arguments
        .split_first()
        .filter(|(_, targets)| !targets.is_empty())
    else {
        return Err(usage(address, "<context-id> <command-address>..."));
    };
    let id = unicode(id, "Context ID")?;
    let targets = targets
        .iter()
        .map(|target| unicode(target, "command address").map(str::to_owned))
        .collect::<ContextResult<Vec<_>>>()?;
    let record = runtime.store.remove_commands(id, &targets)?;
    write_updated(&record)
}

fn note(
    address: &str,
    arguments: &[OsString],
    runtime: &ContextRuntime,
    input: &mut impl Read,
) -> ContextResult<()> {
    let (id, text) = text_input(address, arguments, MAX_NOTE_BYTES, input)?;
    let record = runtime.store.append_note(id, text)?;
    write_updated(&record)
}

fn prompt(
    address: &str,
    arguments: &[OsString],
    runtime: &ContextRuntime,
    input: &mut impl Read,
) -> ContextResult<()> {
    let (id, text) = text_input(address, arguments, MAX_PROMPT_BYTES, input)?;
    let record = runtime.store.set_prompt(id, text)?;
    write_updated(&record)
}

fn show(address: &str, arguments: &[OsString], runtime: &ContextRuntime) -> ContextResult<()> {
    let [id] = arguments else {
        return Err(usage(address, "<context-id>"));
    };
    let record = runtime.store.read(unicode(id, "Context ID")?)?;
    write_json(&record)
}

fn render(address: &str, arguments: &[OsString], runtime: &ContextRuntime) -> ContextResult<()> {
    let [id] = arguments else {
        return Err(usage(address, "<context-id>"));
    };
    let record = runtime.store.read(unicode(id, "Context ID")?)?;
    write_message(&render_markdown(&record))
}

fn list(address: &str, arguments: &[OsString], runtime: &ContextRuntime) -> ContextResult<()> {
    if !(arguments.is_empty() || matches!(arguments, [mode] if mode == "--json")) {
        return Err(usage(address, "[--json]"));
    }
    let records = runtime.store.list()?;
    if arguments.is_empty() {
        let output = if records.is_empty() {
            "No Contexts.".to_owned()
        } else {
            records
                .iter()
                .map(|record| record.id.as_str())
                .collect::<Vec<_>>()
                .join("\n")
        };
        write_message(&output)
    } else {
        let collection = subject_collection(runtime.language, records)?;
        write_json(&collection)
    }
}

fn delete(address: &str, arguments: &[OsString], runtime: &ContextRuntime) -> ContextResult<()> {
    let [id] = arguments else {
        return Err(usage(address, "<context-id>"));
    };
    let id = unicode(id, "Context ID")?;
    runtime.store.delete(id)?;
    write_message(&format!("Context deleted: {id}"))
}

fn text_input<'a>(
    address: &str,
    arguments: &'a [OsString],
    max_bytes: usize,
    input: &mut impl Read,
) -> ContextResult<(&'a str, String)> {
    let Some((id, text_arguments)) = arguments.split_first() else {
        return Err(usage(address, "<context-id> <text...> | --stdin"));
    };
    let id = unicode(id, "Context ID")?;
    let text = match text_arguments {
        [mode] if mode == "--stdin" => read_stdin(input, max_bytes)?,
        [] => return Err(usage(address, "<context-id> <text...> | --stdin")),
        values => values
            .iter()
            .map(|value| unicode(value, "Context text"))
            .collect::<ContextResult<Vec<_>>>()?
            .join(" "),
    };
    validate_text(&text, "Context text", max_bytes)?;
    Ok((id, text))
}

fn read_stdin(input: &mut impl Read, max_bytes: usize) -> ContextResult<String> {
    let mut bytes = Vec::new();
    input
        .take((max_bytes + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|error| ContextError::new(format!("cannot read Context text: {error}")))?;
    if bytes.len() > max_bytes {
        return Err(ContextError::new(format!(
            "Context text from stdin accepts at most {max_bytes} UTF-8 bytes"
        )));
    }
    String::from_utf8(bytes)
        .map_err(|_| ContextError::new("Context text from stdin is not valid UTF-8"))
}

fn write_updated(record: &ContextRecord) -> ContextResult<()> {
    write_message(&format!(
        "Context updated: {} ({} commands, {} notes, prompt: {})",
        record.id,
        record.commands.len(),
        record.notes.len(),
        if record.prompt.is_empty() {
            "no"
        } else {
            "yes"
        }
    ))
}

fn write_json(value: &impl serde::Serialize) -> ContextResult<()> {
    let output = serde_json::to_string_pretty(value)
        .map_err(|error| ContextError::new(format!("cannot serialize Context output: {error}")))?;
    write_message(&output)
}

fn write_message(message: &str) -> ContextResult<()> {
    let stdout = io::stdout();
    let mut handle = stdout.lock();
    writeln!(handle, "{message}")
        .and_then(|()| handle.flush())
        .map_err(|error| ContextError::new(format!("cannot write Context output: {error}")))
}

fn unicode<'a>(value: &'a OsStr, label: &str) -> ContextResult<&'a str> {
    value
        .to_str()
        .ok_or_else(|| ContextError::new(format!("{label} is not valid Unicode")))
}

fn usage(address: &str, suffix: &str) -> ContextError {
    ContextError::new(format!("usage: {address} {suffix}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stdin_preserves_multiline_utf8_and_enforces_the_limit() {
        let mut input = "第一行\n| > & \"第二行\"\n".as_bytes();
        assert_eq!(
            read_stdin(&mut input, MAX_NOTE_BYTES).unwrap(),
            "第一行\n| > & \"第二行\"\n"
        );
        let mut oversized = [b'x'; 5].as_slice();
        assert!(read_stdin(&mut oversized, 4).is_err());
    }

    #[test]
    fn dispatch_and_native_description_share_one_registry() {
        for (command, address) in COMMANDS {
            assert_eq!(Command::from_address(address).unwrap(), *command);
            assert_eq!(command.address(), *address);
        }
    }
}
