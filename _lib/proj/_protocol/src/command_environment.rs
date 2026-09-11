/// Breaking ABI version for the environment supplied to every command process.
///
/// Runtime products validate this value directly. Native execution contracts
/// also bind it into their canonical revision so an environment ABI change
/// makes previously instantiated executables outdated before they can start.
pub const COMMAND_ENVIRONMENT_PROTOCOL: &str = "3";
