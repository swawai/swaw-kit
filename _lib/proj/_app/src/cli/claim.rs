use std::io::{self, IsTerminal, Write};
use std::thread;
use std::time::{Duration, Instant};

use swawkit_proj::data_root::{ClaimApprovalError, DataRootClaim, DataRootClaimApprover};
use windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE;
use windows_sys::Win32::System::Console::{
    GetNumberOfConsoleInputEvents, GetStdHandle, INPUT_RECORD, KEY_EVENT, ReadConsoleInputW,
    STD_INPUT_HANDLE,
};

const DEFAULT_TIMEOUT: Duration = Duration::from_secs(20);
const POLL_INTERVAL: Duration = Duration::from_millis(25);
const VIRTUAL_KEY_BACKSPACE: u16 = 0x08;
const VIRTUAL_KEY_ENTER: u16 = 0x0d;

pub(super) struct ConsoleClaimApprover {
    timeout: Duration,
}

impl Default for ConsoleClaimApprover {
    fn default() -> Self {
        Self {
            timeout: DEFAULT_TIMEOUT,
        }
    }
}

impl DataRootClaimApprover for ConsoleClaimApprover {
    fn approve(&mut self, claim: &DataRootClaim) -> Result<bool, ClaimApprovalError> {
        write_claim(claim, self.timeout)?;
        let answer = read_timed_answer(self.timeout).map_err(|error| {
            ClaimApprovalError::new(format!("cannot read DataRoot confirmation: {error}"))
        })?;
        verify_answer(claim, answer)
    }
}

fn write_claim(claim: &DataRootClaim, timeout: Duration) -> Result<(), ClaimApprovalError> {
    let mut output = io::stdout().lock();
    write_claim_to(&mut output, claim, timeout).map_err(output_error)
}

fn write_claim_to(
    output: &mut impl Write,
    claim: &DataRootClaim,
    timeout: Duration,
) -> io::Result<()> {
    writeln!(
        output,
        "[CLAIM] Project DataRoot requires explicit ownership."
    )?;
    writeln!(
        output,
        "  entry:                    {}",
        claim.entry_file.display()
    )?;
    writeln!(output, "  volumeId:                 {}", claim.volume_id)?;
    writeln!(output, "  fileId:                   {}", claim.file_id)?;
    writeln!(
        output,
        "  target:                   {}",
        claim.data_root.display()
    )?;
    if let Some(source) = &claim.source_data_root {
        writeln!(output, "  source:                   {}", source.display())?;
    }
    writeln!(output, "  reason:                   {}", claim.reason)?;
    write!(
        output,
        "Type the new name '{}' to confirm ({}s timeout): ",
        claim.entry_name,
        timeout.as_secs()
    )?;
    output.flush()
}

fn output_error(error: io::Error) -> ClaimApprovalError {
    ClaimApprovalError::new(format!("cannot write DataRoot confirmation: {error}"))
}

fn read_timed_answer(timeout: Duration) -> io::Result<Option<String>> {
    if !io::stdin().is_terminal() {
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "confirmation requires an interactive terminal",
        ));
    }
    let handle = unsafe { GetStdHandle(STD_INPUT_HANDLE) };
    if handle.is_null() || handle == INVALID_HANDLE_VALUE {
        return Err(io::Error::last_os_error());
    }

    let deadline = Instant::now() + timeout;
    let mut answer = Vec::new();
    let mut output = io::stdout().lock();
    while Instant::now() < deadline {
        if let Some(key) = read_available_key(handle)? {
            match key {
                ConsoleKey::Enter => {
                    writeln!(output)?;
                    return String::from_utf16(&answer).map(Some).map_err(|_| {
                        io::Error::new(
                            io::ErrorKind::InvalidData,
                            "confirmation input is not valid Unicode",
                        )
                    });
                }
                ConsoleKey::Backspace(repeat_count) => {
                    for _ in 0..repeat_count {
                        if answer.pop().is_some() {
                            write!(output, "\u{8} \u{8}")?;
                        }
                    }
                    output.flush()?;
                }
                ConsoleKey::Character(value, repeat_count) => {
                    for _ in 0..repeat_count {
                        answer.push(value);
                        write!(output, "{}", String::from_utf16_lossy(&[value]))?;
                    }
                    output.flush()?;
                }
            }
        } else {
            thread::sleep(POLL_INTERVAL.min(deadline.saturating_duration_since(Instant::now())));
        }
    }
    writeln!(output)?;
    Ok(None)
}

enum ConsoleKey {
    Enter,
    Backspace(u16),
    Character(u16, u16),
}

fn read_available_key(
    handle: windows_sys::Win32::Foundation::HANDLE,
) -> io::Result<Option<ConsoleKey>> {
    let mut event_count = 0;
    if unsafe { GetNumberOfConsoleInputEvents(handle, &mut event_count) } == 0 {
        return Err(io::Error::last_os_error());
    }
    if event_count == 0 {
        return Ok(None);
    }

    let mut record = INPUT_RECORD::default();
    let mut events_read = 0;
    if unsafe { ReadConsoleInputW(handle, &mut record, 1, &mut events_read) } == 0 {
        return Err(io::Error::last_os_error());
    }
    if events_read == 0 || record.EventType != KEY_EVENT as u16 {
        return Ok(None);
    }
    let event = unsafe { record.Event.KeyEvent };
    if event.bKeyDown == 0 {
        return Ok(None);
    }
    let repeat_count = event.wRepeatCount.max(1);
    match event.wVirtualKeyCode {
        VIRTUAL_KEY_ENTER => Ok(Some(ConsoleKey::Enter)),
        VIRTUAL_KEY_BACKSPACE => Ok(Some(ConsoleKey::Backspace(repeat_count))),
        _ => {
            let character = unsafe { event.uChar.UnicodeChar };
            if character >= 0x20 && character != 0x7f {
                Ok(Some(ConsoleKey::Character(character, repeat_count)))
            } else {
                Ok(None)
            }
        }
    }
}

fn verify_answer(
    claim: &DataRootClaim,
    answer: Option<String>,
) -> Result<bool, ClaimApprovalError> {
    let Some(answer) = answer else {
        return Err(ClaimApprovalError::new("project DataRoot claim timed out"));
    };
    if answer != claim.entry_name {
        return Err(ClaimApprovalError::new(format!(
            "project DataRoot claim was not confirmed: expected '{}', received '{answer}'",
            claim.entry_name
        )));
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use swawkit_proj::data_root::ClaimKind;

    fn claim() -> DataRootClaim {
        DataRootClaim {
            kind: ClaimKind::Current,
            entry_name: "project-one".to_owned(),
            entry_file: PathBuf::from(r"C:\launchers\project-one.exe"),
            volume_id: "volume".to_owned(),
            file_id: "file".to_owned(),
            data_root: PathBuf::from(r"C:\swaw\data\proj.project-one"),
            source_data_root: None,
            reason: "unbound candidate".to_owned(),
        }
    }

    #[test]
    fn accepts_only_the_exact_case_sensitive_entry_name() {
        let claim = claim();
        assert!(verify_answer(&claim, Some("project-one".to_owned())).unwrap());
        assert!(
            verify_answer(&claim, Some("Project-One".to_owned()))
                .unwrap_err()
                .to_string()
                .contains("not confirmed")
        );
    }

    #[test]
    fn timeout_is_a_failure_instead_of_implicit_denial() {
        assert!(
            verify_answer(&claim(), None)
                .unwrap_err()
                .to_string()
                .contains("timed out")
        );
    }

    #[test]
    fn claim_prompt_exposes_both_identity_and_move_source() {
        let mut claim = claim();
        claim.source_data_root = Some(PathBuf::from(r"C:\swaw\data\proj.old"));
        let mut output = Vec::new();

        write_claim_to(&mut output, &claim, Duration::from_secs(20)).unwrap();

        let output = String::from_utf8(output).unwrap();
        assert!(output.contains("volumeId:                 volume"));
        assert!(output.contains(r"source:                   C:\swaw\data\proj.old"));
        assert!(output.contains("Type the new name 'project-one'"));
        assert!(output.contains("20s timeout"));
    }
}
