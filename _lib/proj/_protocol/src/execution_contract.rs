use serde::{Deserialize, Serialize};

use crate::{
    CommandIdentity, ModuleProvision, ModuleRequirement, ProtocolError, ProtocolResult, revision,
    validate_module_provisions, validate_module_requirements,
};

pub const EXECUTION_CONTRACT_SCHEMA: &str = "swawkit.native-command-execution-contract/v2";

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "lowercase", deny_unknown_fields)]
pub enum ExecutionSemantics {
    Native,
    Delegate { owner: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ExecutionContractCommand {
    pub address: String,
    pub execution: ExecutionSemantics,
    pub requires: Vec<ModuleRequirement>,
    pub provides: Vec<ModuleProvision>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ExecutionContract {
    schema: String,
    owner: String,
    commands: Vec<ExecutionContractCommand>,
}

impl ExecutionContract {
    pub fn new(
        owner: impl Into<String>,
        mut commands: Vec<ExecutionContractCommand>,
    ) -> ProtocolResult<Self> {
        let owner = owner.into();
        for command in &mut commands {
            command.requires.sort_by(|left, right| {
                (&left.provider, &left.export, &left.contract).cmp(&(
                    &right.provider,
                    &right.export,
                    &right.contract,
                ))
            });
            command.provides.sort_by(|left, right| {
                (&left.id, &left.contract).cmp(&(&right.id, &right.contract))
            });
        }
        commands.sort_by(|left, right| left.address.cmp(&right.address));
        let contract = Self {
            schema: EXECUTION_CONTRACT_SCHEMA.to_owned(),
            owner,
            commands,
        };
        contract.validate()?;
        Ok(contract)
    }

    pub fn owner(&self) -> &str {
        &self.owner
    }

    pub fn commands(&self) -> &[ExecutionContractCommand] {
        &self.commands
    }

    pub fn delegated_commands(&self) -> Vec<String> {
        self.commands
            .iter()
            .filter_map(|command| match command.execution {
                ExecutionSemantics::Delegate { .. } => Some(command.address.clone()),
                ExecutionSemantics::Native => None,
            })
            .collect()
    }

    pub fn canonical_bytes(&self) -> ProtocolResult<Vec<u8>> {
        self.validate()?;
        serde_json::to_vec(self).map_err(|error| {
            ProtocolError::new(format!("cannot serialize execution contract: {error}"))
        })
    }

    pub fn revision(&self) -> ProtocolResult<String> {
        Ok(revision(self.canonical_bytes()?))
    }

    fn validate(&self) -> ProtocolResult<()> {
        let owner_identity = CommandIdentity::parse(&self.owner)?;
        if self.schema != EXECUTION_CONTRACT_SCHEMA
            || self.commands.is_empty()
            || self
                .commands
                .windows(2)
                .any(|pair| pair[0].address >= pair[1].address)
        {
            return Err(ProtocolError::new("invalid execution contract identity"));
        }
        let mut native_count = 0;
        for command in &self.commands {
            let identity = CommandIdentity::parse(&command.address)?;
            validate_requirements(&command.requires)?;
            validate_provisions(&command.provides)?;
            match &command.execution {
                ExecutionSemantics::Native if identity == owner_identity => native_count += 1,
                ExecutionSemantics::Delegate {
                    owner: declared_owner,
                } if declared_owner == &self.owner
                    && owner_identity.is_true_ancestor_of(&identity) => {}
                _ => {
                    return Err(ProtocolError::new(format!(
                        "execution semantics for '{}' do not belong to owner '{}'",
                        command.address, self.owner
                    )));
                }
            }
        }
        if native_count != 1 {
            return Err(ProtocolError::new(
                "execution contract must contain exactly one native owner",
            ));
        }
        Ok(())
    }
}

fn validate_requirements(values: &[ModuleRequirement]) -> ProtocolResult<()> {
    validate_module_requirements(values)?;
    if values.windows(2).any(|pair| {
        (&pair[0].provider, &pair[0].export, &pair[0].contract)
            >= (&pair[1].provider, &pair[1].export, &pair[1].contract)
    }) {
        return Err(ProtocolError::new(
            "execution contract requirements are not canonical",
        ));
    }
    Ok(())
}

fn validate_provisions(values: &[ModuleProvision]) -> ProtocolResult<()> {
    validate_module_provisions(values)?;
    if values
        .windows(2)
        .any(|pair| (&pair[0].id, &pair[0].contract) >= (&pair[1].id, &pair[1].contract))
    {
        return Err(ProtocolError::new(
            "execution contract provisions are not canonical",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn member(address: &str, execution: ExecutionSemantics) -> ExecutionContractCommand {
        ExecutionContractCommand {
            address: address.to_owned(),
            execution,
            requires: Vec::new(),
            provides: Vec::new(),
        }
    }

    #[test]
    fn contract_revision_is_independent_of_declaration_order() {
        let owner = member("swaw/context", ExecutionSemantics::Native);
        let port = member(
            "swaw/context/add",
            ExecutionSemantics::Delegate {
                owner: "swaw/context".to_owned(),
            },
        );
        let left =
            ExecutionContract::new("swaw/context", vec![owner.clone(), port.clone()]).unwrap();
        let right = ExecutionContract::new("swaw/context", vec![port, owner]).unwrap();
        assert_eq!(
            left.canonical_bytes().unwrap(),
            right.canonical_bytes().unwrap()
        );
        assert_eq!(left.revision().unwrap(), right.revision().unwrap());
    }

    #[test]
    fn delegate_must_name_the_exact_native_owner() {
        let error = ExecutionContract::new(
            "swaw/context",
            vec![
                member("swaw/context", ExecutionSemantics::Native),
                member(
                    "swaw/context/add",
                    ExecutionSemantics::Delegate {
                        owner: "swaw/other".to_owned(),
                    },
                ),
            ],
        )
        .unwrap_err();
        assert!(error.to_string().contains("do not belong"));
    }

    #[test]
    fn delegate_address_must_be_below_the_native_owner() {
        let error = ExecutionContract::new(
            "swaw/context",
            vec![
                member("swaw/context", ExecutionSemantics::Native),
                member(
                    "swaw/other/show",
                    ExecutionSemantics::Delegate {
                        owner: "swaw/context".to_owned(),
                    },
                ),
            ],
        )
        .unwrap_err();
        assert!(error.to_string().contains("do not belong"));
    }

    #[test]
    fn system_contract_uses_the_same_execution_semantics() {
        let contract = ExecutionContract::new(
            ".context",
            vec![
                member(".context", ExecutionSemantics::Native),
                member(
                    ".context/add",
                    ExecutionSemantics::Delegate {
                        owner: ".context".to_owned(),
                    },
                ),
            ],
        )
        .unwrap();
        assert_eq!(contract.owner(), ".context");
        assert_eq!(contract.delegated_commands(), [".context/add"]);
    }

    #[test]
    fn delegate_cannot_cross_command_spaces() {
        let error = ExecutionContract::new(
            ".context",
            vec![
                member(".context", ExecutionSemantics::Native),
                member(
                    "swaw/context/add",
                    ExecutionSemantics::Delegate {
                        owner: ".context".to_owned(),
                    },
                ),
            ],
        )
        .unwrap_err();
        assert!(error.to_string().contains("do not belong"));
    }
}
