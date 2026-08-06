use serde::{Deserialize, Serialize};
use std::{fs, io, path::Path};

use super::{
    filesystem::{directory_files, named_directories},
    invalid_data,
};

const WEB_VIEW_SCHEMA: &str = "swawkit.command-view/web/v1";

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandView {
    pub children_column: ChildrenColumnView,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ChildrenColumnView {
    pub width: ColumnWidth,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ColumnWidth {
    Normal,
    Wide,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WebViewManifest {
    schema: String,
    children_column: ChildrenColumnView,
}

pub(super) fn read_local_web_view(command_directory: &Path) -> io::Result<Option<CommandView>> {
    let directories = named_directories(command_directory, "_view")?;
    if directories.len() > 1 {
        return invalid_data(format!(
            "view directory name collision below '{}'",
            command_directory.display()
        ));
    }
    let Some(view_directory) = directories.first() else {
        return Ok(None);
    };
    if view_directory.name != "_view" {
        return invalid_data(format!(
            "non-canonical view directory '{}'; expected '_view'",
            view_directory.name
        ));
    }
    if view_directory.reparse_point {
        return invalid_data(format!(
            "view directory cannot be a reparse point: {}",
            view_directory.path.display()
        ));
    }

    let files = directory_files(&view_directory.path)?
        .into_iter()
        .filter(|file| file.name.eq_ignore_ascii_case("web.json"))
        .collect::<Vec<_>>();
    if files.len() > 1 {
        return invalid_data(format!(
            "Web view file name collision below '{}'",
            view_directory.path.display()
        ));
    }
    let Some(view_file) = files.first() else {
        return Ok(None);
    };
    if view_file.name != "web.json" {
        return invalid_data(format!(
            "non-canonical Web view file '{}'; expected 'web.json'",
            view_file.name
        ));
    }
    if view_file.reparse_point {
        return invalid_data(format!(
            "Web view file cannot be a reparse point: {}",
            view_file.path.display()
        ));
    }

    let content = fs::read_to_string(&view_file.path)?;
    let manifest: WebViewManifest = serde_json::from_str(&content).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "invalid Web command view manifest '{}': {error}",
                view_file.path.display()
            ),
        )
    })?;
    if manifest.schema != WEB_VIEW_SCHEMA {
        return invalid_data(format!(
            "unsupported Web command view schema '{}' in '{}'",
            manifest.schema,
            view_file.path.display()
        ));
    }

    Ok(Some(CommandView {
        children_column: manifest.children_column,
    }))
}
