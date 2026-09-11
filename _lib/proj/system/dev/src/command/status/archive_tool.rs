use swawkit_proj_dev::development::ArchiveToolContract as ArchiveTool;
use swawkit_proj_dev::development::archive_tool::{ArchiveToolRequest, ArchiveToolStore, Trust};
use swawkit_proj_dev::development::setup::declaration::DeclarationSnapshot;

use super::CommandContext;

pub(super) enum ArchiveReport {
    Off,
    System {
        version: String,
        executable: std::path::PathBuf,
    },
    LatestUnresolved {
        repair: String,
    },
    Resolved {
        version_label: String,
        ready: bool,
        trust: Trust,
    },
}

impl ArchiveReport {
    pub(super) fn render(&self, tool: &ArchiveTool) {
        match self {
            Self::Off => println!("[OFF] {} is disabled.", tool.name),
            Self::System {
                version,
                executable,
            } => println!(
                "[READY] {} {version}  system  {}",
                tool.name,
                executable.display()
            ),
            Self::LatestUnresolved { repair } => {
                println!("[MISSING] {} latest unresolved; run '{repair}'", tool.name)
            }
            Self::Resolved {
                version_label,
                ready,
                trust,
            } => {
                let state = if *ready { "READY" } else { "MISSING" };
                println!(
                    "[{state}] {} {version_label}  {}  {}",
                    tool.name,
                    trust.level().as_str(),
                    trust.message()
                );
                if let Some(warning) = trust.warning() {
                    println!("WARNING: {warning}");
                }
            }
        }
    }
}

pub(super) fn inspect(
    context: &CommandContext,
    declarations: &DeclarationSnapshot,
    tool: &ArchiveTool,
) -> Result<ArchiveReport, String> {
    let settings = declarations
        .archive_settings(tool)
        .map_err(|error| error.to_string())?;
    let mode = settings.mode.as_str();
    if mode.is_empty() || mode == "disabled" {
        return Ok(ArchiveReport::Off);
    }
    if tool.name == "pwsh" && mode == "system" {
        let pwsh = swawkit_proj_dev::development::pwsh::resolve_system()?;
        return Ok(ArchiveReport::System {
            version: pwsh.version().to_owned(),
            executable: pwsh.executable().to_path_buf(),
        });
    }
    if mode != "managed" {
        let expected = if tool.name == "pwsh" {
            "'managed', 'system', or 'disabled'"
        } else {
            "'managed' or 'disabled'"
        };
        return Err(format!(
            "Unsupported {} value '{mode}'. Expected {expected}.",
            tool.setting_address("mode"),
        ));
    }

    let requested = settings.version.as_str();
    if requested.is_empty() {
        return Err(format!(
            "Enabled {} must declare {}.",
            tool.display_name,
            tool.setting_address("version")
        ));
    }
    let request = ArchiveToolRequest::new(tool, requested, &settings.sha256)
        .map_err(|error| error.to_string())?;
    let store = ArchiveToolStore::new(&context.data_root, tool);
    let Some(resolved) = store.resolve(&request).map_err(|error| error.to_string())? else {
        return Ok(ArchiveReport::LatestUnresolved {
            repair: context.repair_invocation(),
        });
    };

    let installation = store.read_installation(&resolved).ok();
    let ready = installation
        .as_ref()
        .is_some_and(|value| store.verify_hashes(value).is_ok());
    let trust = store
        .trust(&resolved, installation.as_ref())
        .map_err(|error| error.to_string())?;
    let version_label = if resolved.requested_latest() {
        format!("latest -> {}", resolved.version())
    } else {
        resolved.version().to_owned()
    };
    Ok(ArchiveReport::Resolved {
        version_label,
        ready,
        trust,
    })
}
