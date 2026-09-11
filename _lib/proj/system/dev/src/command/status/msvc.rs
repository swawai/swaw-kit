use swawkit_proj_dev::development::msvc::MsvcStore;
use swawkit_proj_dev::development::setup::declaration::DeclarationSnapshot;

use super::CommandContext;

pub(super) enum MsvcReport {
    Off,
    Managed {
        channel: String,
        versions: Option<(String, String)>,
    },
}

impl MsvcReport {
    pub(super) fn render(&self) {
        match self {
            Self::Off => println!("[OFF] msvc is disabled."),
            Self::Managed { channel, versions } => {
                let (state, version) = match versions {
                    Some((tool, sdk)) => ("READY", format!("tool {tool}, SDK {sdk}")),
                    None => ("MISSING", "not installed".to_owned()),
                };
                println!("[{state}] msvc channel {channel}  microsoft-manifest  {version}");
            }
        }
    }
}

pub(super) fn inspect(
    context: &CommandContext,
    declarations: &DeclarationSnapshot,
) -> Result<MsvcReport, String> {
    let Some(definition) = declarations
        .msvc_definition()
        .map_err(|error| error.to_string())?
    else {
        return Ok(MsvcReport::Off);
    };
    let store = MsvcStore::new(&context.data_root, &definition);
    let versions = store.read_installation().ok().map(|installation| {
        (
            installation.tool_version().to_owned(),
            installation.sdk_version().to_owned(),
        )
    });
    Ok(MsvcReport::Managed {
        channel: definition.channel().to_owned(),
        versions,
    })
}
