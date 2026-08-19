pub mod declaration;
pub mod environment;
pub mod native;
pub mod provider;

pub(crate) mod storage;

pub const PRODUCER_CONTRACT: &str = swawkit_proj_protocol::DEV_SETUP_CONTRACT;
pub const PRODUCER_EXPORT: &str = "environment";
pub const PUBLICATION_TOKEN_VARIABLE: &str =
    "SWAWKIT_PROJ_MODULE_SYSTEM_DEV_SETUP_PUBLICATION_TOKEN";
