use std::ffi::OsStr;

use serde::Serialize;
use serde_json::Value;
use swawkit_proj_protocol::ResourceList;

use crate::command_journal::RunJournalHistoryDocument;

use super::MAX_LATEST_RANGE;
use crate::core_command::CoreCommandError;

pub(super) struct LatestSelector {
    pub(super) start: usize,
    pub(super) end: usize,
}

pub(super) fn parse_after_cursor(cursor: &OsStr) -> Result<u64, CoreCommandError> {
    cursor
        .to_str()
        .ok_or_else(|| CoreCommandError::arguments("after cursor is not valid Unicode"))?
        .parse::<u64>()
        .map_err(|_| CoreCommandError::arguments("after cursor must be an unsigned integer"))
}

pub(super) fn parse_latest_selector(value: &str) -> Result<LatestSelector, CoreCommandError> {
    let (start, end) = match value.split_once("..") {
        Some((start, end)) if !end.contains("..") => {
            (parse_latest_ordinal(start)?, parse_latest_ordinal(end)?)
        }
        None => {
            let ordinal = parse_latest_ordinal(value)?;
            (ordinal, ordinal)
        }
        _ => return Err(latest_selector_error()),
    };
    if start > end || end - start + 1 > MAX_LATEST_RANGE {
        return Err(latest_selector_error());
    }
    Ok(LatestSelector { start, end })
}

pub(super) fn numbered_history(
    document: &RunJournalHistoryDocument,
) -> Result<String, CoreCommandError> {
    let mut value = serde_json::to_value(document).map_err(|error| {
        CoreCommandError::serialization("cannot serialize command journals", error)
    })?;
    let runs = value
        .get_mut("runs")
        .and_then(Value::as_array_mut)
        .ok_or_else(|| CoreCommandError::domain("command journal history invariant failed"))?;
    for (index, run) in runs.iter_mut().enumerate() {
        run.as_object_mut()
            .ok_or_else(|| CoreCommandError::domain("command journal history invariant failed"))?
            .insert("latest".to_owned(), Value::from(index + 1));
    }
    json(&value)
}

pub(super) fn global_history(document: &ResourceList) -> Result<String, CoreCommandError> {
    let mut lines = vec!["Recent Runs:".to_owned()];
    if document.resources().is_empty() {
        lines.push("  none".to_owned());
    } else {
        for (index, resource) in document.resources().iter().enumerate() {
            lines.push(format!(
                "  {}. {}  {}",
                index + 1,
                resource.label(),
                resource.summary()
            ));
            lines.push(format!("     {}", resource.selector()));
        }
    }
    Ok(lines.join("\n"))
}

pub(super) fn json(document: &impl Serialize) -> Result<String, CoreCommandError> {
    serde_json::to_string_pretty(document)
        .map_err(|error| CoreCommandError::serialization("cannot serialize command journal", error))
}

pub(super) fn format_timestamp(milliseconds: u64) -> String {
    let seconds = milliseconds / 1_000;
    let second = seconds % 60;
    let minutes = seconds / 60;
    let minute = minutes % 60;
    let hours = minutes / 60;
    let hour = hours % 24;
    let days = i64::try_from(hours / 24).unwrap_or(i64::MAX);
    let (year, month, day) = civil_date(days);
    format!(
        "{year:04}-{month:02}-{day:02} {hour:02}:{minute:02}:{second:02}.{:03}Z",
        milliseconds % 1_000
    )
}

fn parse_latest_ordinal(value: &str) -> Result<usize, CoreCommandError> {
    value
        .parse::<usize>()
        .ok()
        .filter(|value| *value > 0)
        .ok_or_else(latest_selector_error)
}

fn latest_selector_error() -> CoreCommandError {
    CoreCommandError::arguments(
        "latest selector must be a positive ordinal or inclusive range such as '1..3'",
    )
}

fn civil_date(days_since_epoch: i64) -> (i64, i64, i64) {
    let z = days_since_epoch + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let day_of_era = z - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let mut year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_prime = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_prime + 2) / 5 + 1;
    let month = month_prime + if month_prime < 10 { 3 } else { -9 };
    year += i64::from(month <= 2);
    (year, month, day)
}
