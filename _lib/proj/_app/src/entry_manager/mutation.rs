use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use crate::data_root::DataRootLock;
use crate::entry::EntryId;
use crate::runtime_release::RuntimeReleaseStore;

use super::launcher::LauncherArtifact;
use super::legacy::validate_legacy_record;
use super::target_lease::TargetDataRootLease;
use super::{
    ENTRY_INSTANCE_MUTATION_PROTOCOL, EntryManager, EntryManagerError, EntryMutationDocument,
    EntryMutationOperation, EntryStatus, EntryTarget,
};

static NEXT_STAGE: AtomicU64 = AtomicU64::new(0);

struct ManagerGenerationSnapshot {
    launcher: LauncherArtifact,
    source: RuntimeReleaseStore,
    release_id: String,
}

pub(super) fn create(
    manager: &EntryManager<'_>,
    target: EntryTarget,
) -> Result<EntryMutationDocument, EntryManagerError> {
    let data_directory = manager.context.swawkit_home.join("data");
    let _lock = DataRootLock::acquire(&data_directory)
        .map_err(|error| EntryManagerError::conflict(error.to_string()))?;
    reject_namespace_collisions(&target)?;
    let before = super::inspect::inspect_target(&target)?;
    let target_lease = match before.status {
        EntryStatus::Ready => return mutation(EntryMutationOperation::Create, false, before),
        EntryStatus::Available => {
            let generation = snapshot_manager_generation(manager)?;
            create_fresh(manager, &generation, &target)?
        }
        EntryStatus::Incomplete => {
            let lease = TargetDataRootLease::acquire(&target.data_root)?;
            require_status(
                &super::inspect::inspect_target(&target)?,
                EntryStatus::Incomplete,
                "complete",
            )?;
            let generation = snapshot_manager_generation(manager)?;
            converge_unpublished_runtime(manager, &generation, &target.data_root)?;
            complete_launcher(&generation.launcher, &target)?;
            lease
        }
        _ => {
            return Err(EntryManagerError::conflict(format!(
                "Entry '{}' cannot be created from status {:?}",
                target.name, before.status
            )));
        }
    };
    let after = super::inspect::inspect_target(&target)?;
    require_ready(&after)?;
    drop(target_lease);
    mutation(EntryMutationOperation::Create, true, after)
}

pub(super) fn migrate(
    manager: &EntryManager<'_>,
    target: EntryTarget,
) -> Result<EntryMutationDocument, EntryManagerError> {
    let data_directory = manager.context.swawkit_home.join("data");
    let _lock = DataRootLock::acquire(&data_directory)
        .map_err(|error| EntryManagerError::conflict(error.to_string()))?;
    reject_namespace_collisions(&target)?;
    let before = super::inspect::inspect_target(&target)?;
    if before.status == EntryStatus::Ready {
        return mutation(EntryMutationOperation::Migrate, false, before);
    }
    if before.status != EntryStatus::LegacyMigrationRequired {
        return Err(EntryManagerError::conflict(format!(
            "Entry '{}' cannot be migrated from status {:?}",
            target.name, before.status
        )));
    }
    let target_lease = TargetDataRootLease::acquire(&target.data_root)?;
    require_status(
        &super::inspect::inspect_target(&target)?,
        EntryStatus::LegacyMigrationRequired,
        "migrate",
    )?;
    let generation = snapshot_manager_generation(manager)?;
    validate_legacy_record(&target.data_root, &target.name).map_err(EntryManagerError::conflict)?;
    converge_unpublished_runtime(manager, &generation, &target.data_root)?;
    generation.launcher.install_replace(&target.entry_file)?;
    generation
        .launcher
        .publish_receipt_replace(&target.data_root, &target.name)?;
    EntryId::create_once(&target.data_root)
        .map_err(|error| EntryManagerError::conflict(error.to_string()))?;

    let after = super::inspect::inspect_target(&target)?;
    require_ready(&after)?;
    drop(target_lease);
    mutation(EntryMutationOperation::Migrate, true, after)
}

fn create_fresh(
    manager: &EntryManager<'_>,
    generation: &ManagerGenerationSnapshot,
    target: &EntryTarget,
) -> Result<TargetDataRootLease, EntryManagerError> {
    let stage = stage_path(target)?;
    fs::create_dir(&stage)
        .map_err(|error| EntryManagerError::io("create staged Entry DataRoot", error))?;
    let prepared = (|| {
        EntryId::create_once(&stage).map_err(|error| {
            EntryManagerError::io("create staged Entry identity", std::io::Error::other(error))
        })?;
        generation
            .launcher
            .publish_receipt_create(&stage, &target.name)?;
        converge_unpublished_runtime(manager, generation, &stage)
    })();
    if let Err(error) = prepared {
        cleanup_stage(&stage, &error)?;
        return Err(error);
    }
    if let Err(error) = fs::rename(&stage, &target.data_root) {
        let domain = EntryManagerError::conflict(format!(
            "cannot commit Entry DataRoot '{}': {error}",
            target.data_root.display()
        ));
        cleanup_stage(&stage, &domain)?;
        return Err(domain);
    }
    let lease = TargetDataRootLease::acquire(&target.data_root)?;
    require_status(
        &super::inspect::inspect_target(target)?,
        EntryStatus::Incomplete,
        "finish creating",
    )?;
    generation.launcher.install_create(&target.entry_file)?;
    Ok(lease)
}

fn complete_launcher(
    launcher: &LauncherArtifact,
    target: &EntryTarget,
) -> Result<(), EntryManagerError> {
    // The DataRoot commit can outlive the manager Launcher version that
    // prepared it. Refreshing the receipt before the create-new install makes
    // that crash state converge while an already-present Launcher still fails
    // closed at the filesystem commit boundary.
    launcher.publish_receipt_replace(&target.data_root, &target.name)?;
    launcher.install_create(&target.entry_file)
}

fn reject_namespace_collisions(target: &EntryTarget) -> Result<(), EntryManagerError> {
    let entry_parent = target
        .entry_file
        .parent()
        .ok_or_else(|| EntryManagerError::corrupt("Entry Launcher has no SWAWKIT_HOME parent"))?;
    reject_case_variant(
        entry_parent,
        &format!("{}.exe", target.name),
        &target.entry_file,
        "Entry Launcher",
    )?;
    let data_parent = target
        .data_root
        .parent()
        .ok_or_else(|| EntryManagerError::corrupt("Entry DataRoot has no data directory"))?;
    reject_case_variant(
        data_parent,
        &format!("proj.{}", target.name),
        &target.data_root,
        "Entry DataRoot",
    )
}

fn reject_case_variant(
    directory: &Path,
    expected_name: &str,
    expected_path: &Path,
    label: &str,
) -> Result<(), EntryManagerError> {
    for item in fs::read_dir(directory)
        .map_err(|error| EntryManagerError::io("scan the Entry namespace", error))?
    {
        let item =
            item.map_err(|error| EntryManagerError::io("read an Entry namespace member", error))?;
        if item
            .file_name()
            .to_str()
            .is_some_and(|name| name.eq_ignore_ascii_case(expected_name))
            && item.path() != expected_path
        {
            return Err(EntryManagerError::conflict(format!(
                "{label} has a case-insensitive namespace collision: {}",
                item.path().display()
            )));
        }
    }
    Ok(())
}

fn converge_unpublished_runtime(
    manager: &EntryManager<'_>,
    generation: &ManagerGenerationSnapshot,
    target_data_root: &Path,
) -> Result<(), EntryManagerError> {
    let target = RuntimeReleaseStore::initialize(
        &target_data_root.join("runtime"),
        &manager.context.swawkit_home,
    )
    .map_err(|error| {
        EntryManagerError::conflict(format!("cannot initialize Entry Runtime: {error}"))
    })?;
    match target.selected_release_id() {
        Ok(selected) if selected == generation.release_id => {
            target.validate(&selected).map_err(|error| {
                EntryManagerError::conflict(format!("existing Entry Runtime is invalid: {error}"))
            })?;
            return Ok(());
        }
        Ok(selected) => {
            // Callers have already proved this target cannot launch: it is a
            // staged create, an Incomplete create with no Launcher, or strict
            // legacy migration. A valid older selection may therefore
            // converge forward. Ready Entries never pass through this path.
            target.validate(&selected).map_err(|error| {
                EntryManagerError::conflict(format!(
                    "unpublished Entry Runtime is invalid: {error}"
                ))
            })?;
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => {
            return Err(EntryManagerError::conflict(format!(
                "unpublished Entry Runtime selector is invalid: {error}"
            )));
        }
    }
    target
        .publish_clone_from(&generation.source, &generation.release_id)
        .map_err(|error| EntryManagerError::io("clone the manager Runtime Release", error))?;
    target
        .select(&generation.release_id)
        .map_err(|error| EntryManagerError::io("select the Entry Runtime Release", error))
}

fn snapshot_manager_generation(
    manager: &EntryManager<'_>,
) -> Result<ManagerGenerationSnapshot, EntryManagerError> {
    // The supported updater order is selector -> root Launcher -> Host restart.
    // Reading the Launcher first means an old Host either keeps a coherent A
    // snapshot or observes selector B and refuses to publish mixed artifacts.
    let launcher = LauncherArtifact::read(&manager.context.entry_file)?;
    let source = source_store(manager)?;
    let selected = source.selected_release_id().map_err(|error| {
        EntryManagerError::corrupt(format!("manager Runtime selector is invalid: {error}"))
    })?;
    if selected != manager.context.release_id {
        return Err(EntryManagerError::conflict(format!(
            "manager Host runs Release '{}' but Runtime selects '{selected}'; restart the manager Host before mutating Entries",
            manager.context.release_id
        )));
    }
    source.validate(&selected).map_err(|error| {
        EntryManagerError::corrupt(format!("running manager Release is invalid: {error}"))
    })?;
    Ok(ManagerGenerationSnapshot {
        launcher,
        source,
        release_id: selected,
    })
}

fn source_store(manager: &EntryManager<'_>) -> Result<RuntimeReleaseStore, EntryManagerError> {
    RuntimeReleaseStore::open(&manager.context.runtime_root, &manager.context.swawkit_home)
        .map_err(|error| EntryManagerError::corrupt(format!("manager Runtime is invalid: {error}")))
}

fn mutation(
    operation: EntryMutationOperation,
    changed: bool,
    entry: super::EntryState,
) -> Result<EntryMutationDocument, EntryManagerError> {
    Ok(EntryMutationDocument {
        protocol: ENTRY_INSTANCE_MUTATION_PROTOCOL.to_owned(),
        operation,
        changed,
        entry,
    })
}

fn require_ready(entry: &super::EntryState) -> Result<(), EntryManagerError> {
    if entry.status == EntryStatus::Ready {
        Ok(())
    } else {
        Err(EntryManagerError::corrupt(format!(
            "Entry lifecycle mutation did not commit a ready Entry: {:?}",
            entry.status
        )))
    }
}

fn require_status(
    entry: &super::EntryState,
    expected: EntryStatus,
    operation: &str,
) -> Result<(), EntryManagerError> {
    if entry.status == expected {
        Ok(())
    } else {
        Err(EntryManagerError::conflict(format!(
            "Entry '{}' changed to status {:?} before it could {operation}",
            entry.entry_name, entry.status
        )))
    }
}

fn stage_path(target: &EntryTarget) -> Result<PathBuf, EntryManagerError> {
    let parent = target
        .data_root
        .parent()
        .ok_or_else(|| EntryManagerError::corrupt("Entry DataRoot has no data directory"))?;
    let sequence = NEXT_STAGE.fetch_add(1, Ordering::Relaxed);
    Ok(parent.join(format!(
        ".proj.{}.{}.{sequence}.tmp",
        target.name,
        std::process::id()
    )))
}

fn cleanup_stage(stage: &Path, original: &EntryManagerError) -> Result<(), EntryManagerError> {
    match fs::remove_dir_all(stage) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(EntryManagerError::new(
            original.kind(),
            format!(
                "{original}; staged Entry DataRoot could not be removed '{}': {error}",
                stage.display()
            ),
        )),
    }
}
