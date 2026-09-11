use serde::{Deserialize, Deserializer, Serialize, de::Error as _};

use super::{DEFAULT_LANGUAGE, ENTRY_CONFIG_SCHEMA, EntryConfigError, EntryLanguage};
use crate::binding::validate_project_root;

pub const LANGUAGE_ADDRESS: &str = ".entry/language";
pub const PROJECT_ROOT_ADDRESS: &str = ".entry/project/root";

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EntryConfigRecord {
    pub schema: String,
    pub language: String,
    pub project_root: Option<String>,
}

impl<'de> Deserialize<'de> for EntryConfigRecord {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct WireRecord {
            schema: String,
            language: String,
            project_root: serde_json::Value,
        }

        let record = WireRecord::deserialize(deserializer)?;
        let project_root = match record.project_root {
            serde_json::Value::Null => None,
            serde_json::Value::String(value) => Some(value),
            _ => return Err(D::Error::custom("projectRoot must be a string or null")),
        };
        Ok(Self {
            schema: record.schema,
            language: record.language,
            project_root,
        })
    }
}

impl EntryConfigRecord {
    pub fn validate(&self) -> Result<(), EntryConfigError> {
        if self.schema != ENTRY_CONFIG_SCHEMA {
            return Err(EntryConfigError::new(format!(
                "unsupported entry config schema '{}'",
                self.schema
            )));
        }
        EntryLanguage::parse(&self.language)?;
        if let Some(root) = &self.project_root {
            validate_project_root(root, "projectRoot")
                .map_err(|error| EntryConfigError::new(error.to_string()))?;
        }
        Ok(())
    }

    pub fn setting_addresses() -> [&'static str; 2] {
        [LANGUAGE_ADDRESS, PROJECT_ROOT_ADDRESS]
    }

    pub fn is_setting_address(address: &str) -> bool {
        Self::setting_addresses().contains(&address)
    }

    pub fn setting_value(&self, address: &str) -> Option<Option<&str>> {
        match address {
            LANGUAGE_ADDRESS => Some(Some(&self.language)),
            PROJECT_ROOT_ADDRESS => Some(self.project_root.as_deref()),
            _ => None,
        }
    }

    pub(crate) fn set_setting(
        &mut self,
        address: &str,
        value: Option<String>,
    ) -> Result<(), EntryConfigError> {
        match address {
            LANGUAGE_ADDRESS => {
                self.language = value
                    .ok_or_else(|| EntryConfigError::new(".entry/language cannot be cleared"))?;
            }
            PROJECT_ROOT_ADDRESS => self.project_root = value,
            _ => {
                return Err(EntryConfigError::new(format!(
                    "unknown Entry Config setting: {address}"
                )));
            }
        }
        Ok(())
    }
}

impl Default for EntryConfigRecord {
    fn default() -> Self {
        Self {
            schema: ENTRY_CONFIG_SCHEMA.to_owned(),
            language: DEFAULT_LANGUAGE.to_owned(),
            project_root: None,
        }
    }
}
