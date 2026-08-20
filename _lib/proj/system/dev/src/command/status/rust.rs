use super::CommandContext;
use swawkit_proj_dev::development::rust::RustStore;
use swawkit_proj_dev::development::setup::declaration::DeclarationSnapshot;

pub(super) enum RustReport {
    Off,
    Rustup {
        toolchain: String,
        versions: Option<(String, String)>,
    },
}

impl RustReport {
    pub(super) fn render(&self) {
        match self {
            Self::Off => println!("[OFF] rust is disabled."),
            Self::Rustup {
                toolchain,
                versions,
            } => {
                let (state, version) = versions.as_ref().map_or_else(
                    || ("MISSING", "not installed".to_owned()),
                    |(rustc, cargo)| ("READY", format!("rustc {rustc}, cargo {cargo}")),
                );
                println!("[{state}] rust {toolchain}  rust-static-sha256  {version}");
            }
        }
    }
}

pub(super) fn inspect(
    context: &CommandContext,
    declarations: &DeclarationSnapshot,
) -> Result<RustReport, String> {
    let Some(definition) = declarations
        .rust_definition()
        .map_err(|error| error.to_string())?
    else {
        return Ok(RustReport::Off);
    };
    let versions = RustStore::new(&context.data_root, &definition)
        .read_installation()
        .ok()
        .map(|installation| {
            (
                installation.rustc_version().to_owned(),
                installation.cargo_version().to_owned(),
            )
        });
    Ok(RustReport::Rustup {
        toolchain: definition.toolchain().to_owned(),
        versions,
    })
}
