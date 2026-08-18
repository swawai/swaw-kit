use serde::{Deserialize, Serialize};

use crate::address::command_reference;
use crate::error::{ContextError, ContextResult};

pub const CONTEXT_SCHEMA: &str = "swawkit.context/v2";
pub const LEGACY_CONTEXT_SCHEMA: &str = "swawkit.context/v1";
pub const MAX_CONTEXT_BYTES: usize = 128 * 1024;
pub const MAX_CONTEXT_COMMANDS: usize = 128;
pub const MAX_CONTEXT_NOTES: usize = 128;
pub const MAX_NOTE_BYTES: usize = 8 * 1024;
pub const MAX_PROMPT_BYTES: usize = 32 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum CommandSpace {
    System,
    Module,
}

impl CommandSpace {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::System => "system",
            Self::Module => "module",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ContextCommand {
    pub space: CommandSpace,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub namespace: Option<String>,
    pub address: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ContextRecord {
    pub schema: String,
    pub id: String,
    pub commands: Vec<ContextCommand>,
    pub notes: Vec<String>,
    pub prompt: String,
}

impl ContextRecord {
    pub(crate) fn empty(id: &str) -> Self {
        Self {
            schema: CONTEXT_SCHEMA.to_owned(),
            id: id.to_owned(),
            commands: Vec::new(),
            notes: Vec::new(),
            prompt: String::new(),
        }
    }

    pub(crate) fn validate(&self) -> ContextResult<()> {
        if self.schema != CONTEXT_SCHEMA {
            return Err(ContextError::new(format!(
                "unsupported Context schema '{}'",
                self.schema
            )));
        }
        validate_id(&self.id)?;
        if self.commands.len() > MAX_CONTEXT_COMMANDS {
            return Err(ContextError::new(format!(
                "a Context accepts at most {MAX_CONTEXT_COMMANDS} commands"
            )));
        }
        if self.notes.len() > MAX_CONTEXT_NOTES {
            return Err(ContextError::new(format!(
                "a Context accepts at most {MAX_CONTEXT_NOTES} notes"
            )));
        }
        for command in &self.commands {
            let parsed = command_reference(&command.address)?;
            if parsed.space != command.space || parsed.namespace != command.namespace {
                return Err(ContextError::new(format!(
                    "Context command identity does not match its address: {}",
                    command.address
                )));
            }
        }
        if has_duplicate_commands(&self.commands) {
            return Err(ContextError::new(
                "a Context cannot contain duplicate commands",
            ));
        }
        for note in &self.notes {
            validate_text(note, "Context note", MAX_NOTE_BYTES)?;
        }
        if !self.prompt.is_empty() {
            validate_text(&self.prompt, "Context prompt", MAX_PROMPT_BYTES)?;
        }
        Ok(())
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct LegacyContextRecord {
    pub(crate) schema: String,
    pub(crate) id: String,
    pub(crate) commands: Vec<LegacyContextCommand>,
    pub(crate) notes: Vec<String>,
    pub(crate) prompt: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct LegacyContextCommand {
    pub(crate) source: LegacyCommandSource,
    pub(crate) address: String,
}

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum LegacyCommandSource {
    Control,
    Kernel,
    Action,
}

impl LegacyContextRecord {
    pub(crate) fn into_current(self) -> ContextResult<ContextRecord> {
        if self.schema != LEGACY_CONTEXT_SCHEMA {
            return Err(ContextError::new(format!(
                "unsupported legacy Context schema '{}'",
                self.schema
            )));
        }
        let record = ContextRecord {
            schema: CONTEXT_SCHEMA.to_owned(),
            id: self.id,
            commands: self
                .commands
                .into_iter()
                .map(LegacyContextCommand::into_current)
                .collect::<ContextResult<Vec<_>>>()?,
            notes: self.notes,
            prompt: self.prompt,
        };
        record.validate()?;
        Ok(record)
    }
}

impl LegacyContextCommand {
    fn into_current(self) -> ContextResult<ContextCommand> {
        let address = match self.source {
            LegacyCommandSource::Control => {
                let path = self.address.strip_prefix("..").ok_or_else(|| {
                    ContextError::new(format!("invalid legacy control address: {}", self.address))
                })?;
                format!(".{}", path.replace('.', "/"))
            }
            LegacyCommandSource::Kernel => {
                let path = self.address.strip_prefix('.').ok_or_else(|| {
                    ContextError::new(format!("invalid legacy kernel address: {}", self.address))
                })?;
                format!(".{}", path.replace('.', "/"))
            }
            LegacyCommandSource::Action => {
                format!("project/{}", self.address.replace('.', "/"))
            }
        };
        command_reference(&address)
    }
}

pub(crate) fn validate_id(id: &str) -> ContextResult<()> {
    let mut bytes = id.bytes();
    let valid = !id.is_empty()
        && id.len() <= 64
        && matches!(bytes.next(), Some(b'a'..=b'z'))
        && bytes.all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
        && !is_windows_device_name(id);
    if valid {
        Ok(())
    } else {
        Err(ContextError::new(
            "Context ID must match [a-z][a-z0-9-]{0,63} and cannot be a Windows device name",
        ))
    }
}

pub(crate) fn validate_text(value: &str, label: &str, max_bytes: usize) -> ContextResult<()> {
    if value.trim().is_empty() {
        return Err(ContextError::new(format!("{label} cannot be empty")));
    }
    if value.contains('\0') {
        return Err(ContextError::new(format!(
            "{label} cannot contain NUL characters"
        )));
    }
    if value.len() > max_bytes {
        return Err(ContextError::new(format!(
            "{label} accepts at most {max_bytes} UTF-8 bytes"
        )));
    }
    Ok(())
}

pub(crate) fn validate_command_address(address: &str) -> ContextResult<()> {
    if address.is_empty() || address.len() > 4096 || address.contains('\0') {
        Err(ContextError::new(
            "Context command address must be non-empty, contain no NUL, and use at most 4096 UTF-8 bytes",
        ))
    } else {
        Ok(())
    }
}

fn has_duplicate_commands(commands: &[ContextCommand]) -> bool {
    commands
        .iter()
        .enumerate()
        .any(|(index, command)| commands[..index].contains(command))
}

pub(crate) fn is_windows_device_name(id: &str) -> bool {
    matches!(
        id,
        "con"
            | "prn"
            | "aux"
            | "nul"
            | "com1"
            | "com2"
            | "com3"
            | "com4"
            | "com5"
            | "com6"
            | "com7"
            | "com8"
            | "com9"
            | "lpt1"
            | "lpt2"
            | "lpt3"
            | "lpt4"
            | "lpt5"
            | "lpt6"
            | "lpt7"
            | "lpt8"
            | "lpt9"
    )
}
