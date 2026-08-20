import { createCatalog } from "./catalog-model.js";
import {
  createSubjectFacetView,
  defaultCommandFacet,
} from "./subject-facet.js";
import { createCommandRunView } from "./command-run.js";
import { createContextProjectionRenderer } from "./context-projection.js";
import { createContextTrayView } from "./context-tray.js";
import { createDetailView } from "./detail.js";
import { createDocumentProjectionView } from "./document-projection.js";
import { createExplorerView } from "./explorer.js";
import { createEntryProfileView } from "./entry-profile.js";
import { setLanguage, t } from "./i18n.js";
import { createCommandCheckProjectionRenderer } from "./command-check-projection.js";
import { createRuntimeControlView } from "./runtime-control.js";
import { createRunProjectionRenderer } from "./run-projection.js";
import { createEntryManagerView } from "./entry-manager-view.js";
import {
  createCollectionResolutionLoader,
  resolveFacet,
} from "./facet-resolution-client.js";
import {
  commandAtPath,
  parseCommandSelection,
  restoreCommandSelection,
  updateCommandPath,
} from "./navigation.js";

const elements = {
  cliCommand: document.querySelector("#cli-command"),
  commandDetail: document.querySelector("#command-detail"),
  commandHelpPane: document.querySelector("#command-help-pane"),
  commandHelpAddress: document.querySelector("#command-help-address"),
  commandRunPane: document.querySelector("#command-run-pane"),
  commandRunAdd: document.querySelector("#command-run-add"),
  commandRunAddress: document.querySelector("#command-run-address"),
  commandRunActions: document.querySelector("#command-run-actions"),
  commandRunArguments: document.querySelector("#command-run-arguments"),
  commandRunCancel: document.querySelector("#command-run-cancel"),
  commandRunConfirm: document.querySelector("#command-run-confirm"),
  commandRunConfirmation: document.querySelector("#command-run-confirmation"),
  commandRunConfirmationText: document.querySelector("#command-run-confirmation-text"),
  commandRunConfirmDismiss: document.querySelector("#command-run-confirm-dismiss"),
  commandRunEditor: document.querySelector("#command-run-editor"),
  commandRunEmpty: document.querySelector("#command-run-empty"),
  commandRunExitCode: document.querySelector("#command-run-exit-code"),
  commandRunFeedback: document.querySelector("#command-run-feedback"),
  commandRunForm: document.querySelector("#command-run-form"),
  commandRunOutput: document.querySelector("#command-run-output"),
  commandRunOperationList: document.querySelector("#command-run-operation-list"),
  commandRunOperations: document.querySelector("#command-run-operations"),
  commandRunResult: document.querySelector("#command-run-result"),
  commandRunSection: document.querySelector("#command-run-section"),
  commandRunState: document.querySelector("#command-run-state"),
  commandRunSubmit: document.querySelector("#command-run-submit"),
  commandRunTruncated: document.querySelector("#command-run-truncated"),
  commandWorkspace: document.querySelector("#command-workspace"),
  contextProjectionPane: document.querySelector("#context-projection-pane"),
  contextProjectionCommandEmpty: document.querySelector("#context-projection-command-empty"),
  contextProjectionCommands: document.querySelector("#context-projection-commands"),
  contextProjectionNotes: document.querySelector("#context-projection-notes"),
  contextProjectionNotesEmpty: document.querySelector("#context-projection-notes-empty"),
  contextProjectionPin: document.querySelector("#context-projection-pin"),
  contextProjectionPinLabel: document.querySelector("#context-projection-pin-label"),
  contextProjectionPinnedLabel: document.querySelector("#context-projection-pinned-label"),
  contextProjectionPrompt: document.querySelector("#context-projection-prompt"),
  contextProjectionPromptEmpty: document.querySelector("#context-projection-prompt-empty"),
  contextProjectionRef: document.querySelector("#context-projection-ref"),
  contextProjectionSummary: document.querySelector("#context-projection-summary"),
  contextProjectionTitle: document.querySelector("#context-projection-title"),
  contextTray: document.querySelector("#context-tray"),
  contextTrayAdd: document.querySelector("#context-tray-add"),
  contextTrayAddLabel: document.querySelector("#context-tray-add-label"),
  contextTrayCommand: document.querySelector("#context-tray-command"),
  contextTrayCommandEmpty: document.querySelector("#context-tray-command-empty"),
  contextTrayCommands: document.querySelector("#context-tray-commands"),
  contextTrayFeedback: document.querySelector("#context-tray-feedback"),
  contextTrayNotes: document.querySelector("#context-tray-notes"),
  contextTrayNotesEmpty: document.querySelector("#context-tray-notes-empty"),
  contextTrayPresentLabel: document.querySelector("#context-tray-present-label"),
  contextTrayPrompt: document.querySelector("#context-tray-prompt"),
  contextTrayPromptEmpty: document.querySelector("#context-tray-prompt-empty"),
  contextTrayRef: document.querySelector("#context-tray-ref"),
  contextTraySummary: document.querySelector("#context-tray-summary"),
  contextTrayTitle: document.querySelector("#context-tray-title"),
  contextTrayUnpin: document.querySelector("#context-tray-unpin"),
  copyButton: document.querySelector("#copy-button"),
  copyFeedback: document.querySelector("#copy-feedback"),
  copyLabel: document.querySelector("#copy-label"),
  detailAddress: document.querySelector("#detail-address"),
  detailHelp: document.querySelector("#detail-help"),
  detailIssue: document.querySelector("#detail-issue"),
  detailPanel: document.querySelector("#detail-panel"),
  detailSummary: document.querySelector("#detail-summary"),
  documentProjectionFeedback: document.querySelector("#document-projection-feedback"),
  documentProjectionJson: document.querySelector("#document-projection-json"),
  documentProjectionPane: document.querySelector("#document-projection-pane"),
  documentProjectionProtocol: document.querySelector("#document-projection-protocol"),
  documentProjectionRef: document.querySelector("#document-projection-ref"),
  documentProjectionTitle: document.querySelector("#document-projection-title"),
  errorMessage: document.querySelector("#error-message"),
  errorState: document.querySelector("#error-state"),
  explorerFrame: document.querySelector("#explorer-frame"),
  explorerFlow: document.querySelector("#explorer-flow"),
  finderColumns: document.querySelector("#finder-columns"),
  genericCommandOverview: document.querySelector("#generic-command-overview"),
  invocationSection: document.querySelector("#invocation-section"),
  issueCard: document.querySelector("#issue-card"),
  loadingState: document.querySelector("#loading-state"),
  moduleContractSection: document.querySelector("#module-contract-section"),
  commandCheckDependencies: document.querySelector("#command-check-dependencies"),
  commandCheckDiagnostic: document.querySelector("#command-check-diagnostic"),
  commandCheckMeta: document.querySelector("#command-check-meta"),
  commandCheckPane: document.querySelector("#command-check-pane"),
  commandCheckState: document.querySelector("#command-check-state"),
  commandCheckTitle: document.querySelector("#command-check-title"),
  moduleProvides: document.querySelector("#module-provides"),
  moduleRequires: document.querySelector("#module-requires"),
  propertyAddress: document.querySelector("#property-address"),
  propertyEntry: document.querySelector("#property-entry"),
  propertyEntryRow: document.querySelector("#property-entry-row"),
  profileFeedback: document.querySelector("#profile-feedback"),
  profileForm: document.querySelector("#profile-form"),
  profileSaveButton: document.querySelector("#profile-save-button"),
  profileState: document.querySelector("#profile-state"),
  profileValue: document.querySelector("#profile-value"),
  profileSettingAddress: document.querySelector("#profile-setting-address"),
  retryButton: document.querySelector("#retry-button"),
  runtimeCleanupApply: document.querySelector("#runtime-cleanup-apply"),
  runtimeCleanupFeedback: document.querySelector("#runtime-cleanup-feedback"),
  runtimeCleanupList: document.querySelector("#runtime-cleanup-list"),
  runtimeCleanupPreview: document.querySelector("#runtime-cleanup-preview"),
  runtimeCleanupResult: document.querySelector("#runtime-cleanup-result"),
  runtimeCleanupSection: document.querySelector("#runtime-cleanup-section"),
  runtimeCleanupSummary: document.querySelector("#runtime-cleanup-summary"),
  runtimeControl: document.querySelector("#runtime-control"),
  runtimeDescription: document.querySelector("#runtime-description"),
  runtimeHostConnection: document.querySelector("#runtime-host-connection"),
  runtimeHostActions: document.querySelector("#runtime-host-actions"),
  runtimeHostExit: document.querySelector("#runtime-host-exit"),
  runtimeHostFeedback: document.querySelector("#runtime-host-feedback"),
  runtimeHostPid: document.querySelector("#runtime-host-pid"),
  runtimeHostProperties: document.querySelector("#runtime-host-properties"),
  runtimeHostRestart: document.querySelector("#runtime-host-restart"),
  runtimeHostSection: document.querySelector("#runtime-host-section"),
  runtimeHostStatus: document.querySelector("#runtime-host-status"),
  runtimeReleaseCount: document.querySelector("#runtime-release-count"),
  runtimeRunningRelease: document.querySelector("#runtime-running-release"),
  runtimeSelectedRelease: document.querySelector("#runtime-selected-release"),
  runtimeTitle: document.querySelector("#runtime-title"),
  runProjectionError: document.querySelector("#run-projection-error"),
  runProjectionMeta: document.querySelector("#run-projection-meta"),
  runProjectionOutput: document.querySelector("#run-projection-output"),
  runProjectionPane: document.querySelector("#run-projection-pane"),
  runProjectionRef: document.querySelector("#run-projection-ref"),
  runProjectionState: document.querySelector("#run-projection-state"),
  runProjectionTitle: document.querySelector("#run-projection-title"),
  runProjectionTruncated: document.querySelector("#run-projection-truncated"),
  selectionStatus: document.querySelector("#selection-status"),
  entryProfileDetail: document.querySelector("#entry-profile-detail"),
  entryProfileSummary: document.querySelector("#entry-profile-summary"),
  entryProfileTitle: document.querySelector("#entry-profile-title"),
  workspace: document.querySelector("#workspace"),
  catalogCanvas: document.querySelector("#catalog-canvas"),
  entryManagerNavigation: document.querySelector("#entry-manager-navigation"),
  entryManagerTab: document.querySelector("#entry-manager-tab"),
  entryConsoleTab: document.querySelector("#entry-console-tab"),
  entryManagerPanel: document.querySelector("#entry-manager-panel"),
  entryManagerForm: document.querySelector("#entry-manager-form"),
  entryManagerInput: document.querySelector("#entry-manager-input"),
  entryManagerHome: document.querySelector("#entry-manager-home"),
  entryManagerEntryFile: document.querySelector("#entry-manager-entry-file"),
  entryManagerDataRoot: document.querySelector("#entry-manager-data-root"),
  entryManagerState: document.querySelector("#entry-manager-state"),
  entryManagerIssues: document.querySelector("#entry-manager-issues"),
  entryManagerFeedback: document.querySelector("#entry-manager-feedback"),
  entryManagerCreate: document.querySelector("#entry-manager-create"),
  entryManagerMigrate: document.querySelector("#entry-manager-migrate"),
  entryManagerRefresh: document.querySelector("#entry-manager-refresh"),
  entryManagerInventory: document.querySelector("#entry-manager-inventory"),
  entryManagerInventoryEmpty: document.querySelector("#entry-manager-inventory-empty"),
};

let catalog = null;
let contextTray = null;
const detail = createDetailView(elements);
const commandRun = createCommandRunView(elements, {
  onCompleted(snapshot) {
    if (selectedSubject) {
      void refreshSelectedSubjectCollection();
    }
    contextTray?.operationCompleted(snapshot.address);
  },
});
const commandFacet = createSubjectFacetView(elements, {
  defaultFacet: defaultCommandFacet,
  fallbackRenderer: "overview",
});
const subjectFacet = createSubjectFacetView();
const contextProjection = createContextProjectionRenderer(elements, {
  onPin(subject, document) {
    void contextTray?.pin(subject, document);
  },
});
const documentProjection = createDocumentProjectionView(elements, {
  renderers: [
    createCommandCheckProjectionRenderer(elements),
    contextProjection,
    createRunProjectionRenderer(elements),
  ],
  resolveDocument(subject, facet) {
    return resolveFacet(catalog, subject, facet, { via: subject.via });
  },
});
let selectedSubject = null;
let selectedSubjectFacet = null;
let runtimeControl = null;
const entryProfile = createEntryProfileView(elements, {
  async onProfileChanged(document) {
    setLanguage(document.profile.language);
    void runtimeControl?.load();
    explorer.setSetupRequired(!document.requiredComplete);
    await loadCatalog();
  },
});
const explorer = createExplorerView({
  columns: elements.finderColumns,
  detailPanel: elements.detailPanel,
  getCommandFacets(command) {
    return commandFacet.items(command);
  },
  getSubjectFacets(subject) {
    return subjectFacet.items(subject);
  },
  onSelectCommand(command, options = {}) {
    selectedSubject = null;
    selectedSubjectFacet = null;
    subjectFacet.select(null);
    contextTray?.selectCommand(command);
    entryProfile.render(command);
    detail.render(catalog, command);
    runtimeControl?.select(command);
    const selection = commandFacet.select(command, { facet: options.facet });
    const showsDocumentProjection = documentProjection.select(command, selection.facet);
    const runResolver = selection.facet?.renderer === "run"
      ? selection.facet.resolver
      : null;
    const runCommand = runResolver?.type === "command"
      ? catalog.commandByAddress.get(runResolver.address) ?? null
      : null;
    commandRun.select(runCommand, {
      acceptsTail: runResolver?.acceptsTail ?? true,
      arguments: runResolver?.arguments ?? [],
      confirmation: runResolver?.confirmation ?? null,
      key: runResolver ? `${command.address}#${selection.facet.id}` : null,
      label: selection.facet?.label ?? null,
      useOperations: selection.facet?.id === "run",
    });
    if (showsDocumentProjection) {
      elements.commandDetail.hidden = true;
    }
    elements.detailPanel.dataset.view = selection.facet?.renderer ?? "";
    elements.detailPanel.hidden = selection.facet?.kind === "collection";
    if (
      selection.facet?.kind === "collection"
      && selection.facet.resolver?.type === "command"
    ) {
      void loadCollection(command.address, selection.facet.id).catch(() => {});
    }
    updateCommandPath(
      window.history,
      window.location,
      command,
      {
        defaultFacet: selection.defaultFacet,
        facet: selection.selectedFacet,
        mode: options.history ?? "none",
      },
    );
  },
  onSelectSubject(subject, options = {}) {
    selectedSubject = subject;
    const owner = catalog.commandByAddress.get(subject.owner);
    entryProfile.render(null);
    runtimeControl?.select(null);
    contextTray?.selectCommand(null);
    commandFacet.select(owner, { facet: subject.collectionFacet });
    const selection = subjectFacet.select(subject, { facet: options.facet });
    selectedSubjectFacet = selection.selectedFacet;
    const resolver = selection.facet?.resolver ?? null;
    const runCommand = selection.facet?.renderer === "run" && resolver?.type === "command"
      ? catalog.commandByAddress.get(resolver.address) ?? null
      : null;
    commandRun.select(runCommand, {
      acceptsTail: resolver?.acceptsTail ?? false,
      arguments: resolver?.arguments ?? [],
      confirmation: resolver?.confirmation ?? null,
      key: resolver ? `${subject.canonicalRef}#${selection.facet.id}` : null,
      label: selection.facet?.label ?? null,
      useOperations: false,
    });
    const runView = selection.facet?.renderer === "run";
    const showsDocumentProjection = documentProjection.select(subject, selection.facet);
    elements.commandWorkspace.hidden = !(runView || showsDocumentProjection);
    elements.commandRunPane.hidden = !runView;
    elements.detailPanel.dataset.view = selection.facet?.renderer ?? "";
    elements.detailPanel.hidden = false;
    elements.selectionStatus.textContent = t(
      `已选择对象 ${subject.canonicalRef}`,
      `Selected subject ${subject.canonicalRef}`,
    );
    updateCommandPath(
      window.history,
      window.location,
      owner,
      {
        defaultSubjectFacet: selection.defaultFacet,
        facet: subject.collectionFacet,
        mode: options.history ?? "none",
        subject: subject.canonicalRef,
        subjectFacet: selection.selectedFacet,
      },
    );
  },
});
const collectionLoader = createCollectionResolutionLoader({
  onError(owner, facet, error) {
    explorer.setSubjectCollectionError(
      owner,
      facet,
      error instanceof Error ? error.message : "Cannot resolve Subject collection.",
    );
  },
  onLoading(owner, facet) {
    explorer.setSubjectCollectionLoading(owner, facet);
  },
  onResolved(collection) {
    explorer.setSubjectCollection(collection);
  },
  async resolveCollection(owner, facet) {
    const command = catalog.commandByAddress.get(owner);
    const selectedFacet = command?.facets.find((candidate) => candidate.id === facet);
    if (!command || selectedFacet?.kind !== "collection") {
      throw new Error(`Cannot resolve missing collection Facet ${owner}#${facet}.`);
    }
    return resolveFacet(catalog, command, selectedFacet);
  },
});
contextTray = createContextTrayView(elements, {
  async loadDocument(subject) {
    const overview = subject.facets.find((facet) => (
      facet.id === "overview"
      && facet.kind === "projection"
      && facet.resolver?.returns === "swawkit.context/v2"
    ));
    if (!overview) {
      throw new Error(t(
        "固定 Context 不再提供概览能力。",
        "The pinned Context no longer provides an overview capability.",
      ));
    }
    return resolveFacet(catalog, subject, overview, { via: subject.via });
  },
  async loadSubject(record) {
    const owner = record.via.subject.address;
    const collection = await loadCollection(owner, record.via.facet);
    const reference = `::${record.subject.kind}/${record.subject.id}`;
    return collection?.subjectByRef.get(reference) ?? null;
  },
  onPinnedChange(reference) {
    contextProjection.setPinnedRef(reference);
  },
  storage: window.sessionStorage,
});
runtimeControl = createRuntimeControlView(elements, {
  onRuntimeState(state) {
    explorer.setCommandState(".runtime", state);
  },
});
const entryManager = createEntryManagerView(elements);

function setLoadState(status, message = "") {
  const loading = status === "loading";
  const failed = status === "error";

  elements.loadingState.hidden = !loading;
  elements.errorState.hidden = !failed;
  elements.explorerFlow.hidden = status !== "ready";
  elements.explorerFrame.setAttribute("aria-busy", String(loading));

  if (failed) {
    elements.errorMessage.textContent = message || t("无法连接 Host。", "Cannot connect to Host.");
  }
}

async function startApplication() {
  setLoadState("loading");
  try {
    await loadApplication();
  } catch (error) {
    const message = error instanceof Error
      ? error.message
      : t(
        "读取 DataRoot 状态时发生未知错误。",
        "An unknown error occurred while loading the application.",
      );
    setLoadState("error", message);
  }
}

async function loadCollection(owner, facet) {
  return collectionLoader.load(owner, facet);
}

async function refreshSelectedSubjectCollection() {
  const selectedRef = selectedSubject?.canonicalRef ?? null;
  const owner = selectedSubject?.owner ?? null;
  const facet = selectedSubject?.collectionFacet ?? null;
  const selectedFacet = selectedSubjectFacet;
  if (!owner || !facet) {
    return;
  }
  try {
    const collection = await loadCollection(owner, facet);
    if (
      selectedRef
      && selectedSubject?.canonicalRef === selectedRef
      && collection?.subjectByRef.has(selectedRef)
    ) {
      explorer.selectSubject(owner, facet, selectedRef, {
        history: "replace",
        facet: selectedFacet,
      });
    }
  } catch (error) {
    elements.commandRunFeedback.textContent = error instanceof Error
      ? error.message
      : t("刷新 Subject 集合时发生未知错误。", "An unknown error occurred while refreshing Subjects.");
    elements.commandRunFeedback.dataset.state = "error";
  }
}

async function applyCatalogRoute(document, mode = "replace") {
  const routed = commandAtPath(catalog, window.location.pathname, {
    allowMissing: !document.requiredComplete,
  });
  const route = parseCommandSelection(window.location.search);
  if (route.subject && !routed) {
    throw new Error(t("Subject URL 缺少命令所有者。", "A Subject URL requires its command owner."));
  }
  await restoreCommandSelection({
    collectionFacet: route.facet,
    loadCollection,
    ownerAddress: routed?.address ?? null,
    selectOwner() {
      explorer.setCatalog(catalog, {
        address: routed?.address,
        history: mode,
        facet: route.facet,
      });
      return true;
    },
    selectSubject(owner, facet, subject, options) {
      return explorer.selectSubject(owner, facet, subject, {
        ...options,
        history: mode,
      });
    },
    subjectFacet: route.subjectFacet,
    subjectRef: route.subject,
  });
}

async function loadCatalog() {
  setLoadState("loading");
  try {
    const response = await fetch("/api/v2/catalog", {
      cache: "no-store",
      headers: { Accept: "application/json" },
    });
    if (!response.ok) {
      throw new Error(t(`Host 返回 HTTP ${response.status}`, `Host returned HTTP ${response.status}`));
    }

    catalog = createCatalog(await response.json());
    const document = await entryProfile.loadProfile();
    await applyCatalogRoute(document);
    await contextTray.restore();
    await entryManager.activate(catalog.entryName);
    setLoadState("ready");
  } catch (error) {
    const message = error instanceof Error
      ? error.message
      : t("读取 Catalog 时发生未知错误。", "An unknown error occurred while loading the Catalog.");
    setLoadState("error", message);
  }
}

async function loadApplication() {
  setLoadState("loading");
  try {
    const document = await entryProfile.loadProfile();
    setLanguage(document.profile.language);
    void commandRun.restore();
    void runtimeControl.load();
    explorer.setSetupRequired(!document.requiredComplete);
    const response = await fetch("/api/v2/catalog", {
      cache: "no-store",
      headers: { Accept: "application/json" },
    });
    if (!response.ok) {
      throw new Error(t(`Host 返回 HTTP ${response.status}`, `Host returned HTTP ${response.status}`));
    }
    catalog = createCatalog(await response.json());
    await applyCatalogRoute(document);
    await contextTray.restore();
    await entryManager.activate(catalog.entryName);
    setLoadState("ready");
  } catch (error) {
    const message = error instanceof Error
      ? error.message
      : t(
        "读取控制台状态时发生未知错误。",
        "An unknown error occurred while loading console state.",
      );
    setLoadState("error", message);
  }
}

elements.copyButton.addEventListener("click", detail.copyInvocation);
elements.profileForm.addEventListener("submit", (event) => {
  event.preventDefault();
  entryProfile.saveProfile();
});
elements.finderColumns.addEventListener("keydown", explorer.handleKeyboard);
elements.retryButton.addEventListener("click", startApplication);
window.addEventListener("popstate", async () => {
  if (!catalog) {
    return;
  }
  try {
    const routed = commandAtPath(catalog, window.location.pathname);
    const route = parseCommandSelection(window.location.search);
    if (route.subject && !routed) {
      throw new Error(t("Subject URL 缺少命令所有者。", "A Subject URL requires its command owner."));
    }
    let selectedOwner = false;
    const restored = await restoreCommandSelection({
      collectionFacet: route.facet,
      loadCollection,
      ownerAddress: routed?.address ?? null,
      selectOwner() {
        selectedOwner = Boolean(routed && explorer.selectAddress(routed.address, {
          history: "none",
          facet: route.facet,
        }));
        if (!selectedOwner) {
          explorer.setCatalog(catalog, { history: "replace" });
        }
        return selectedOwner;
      },
      selectSubject(owner, facet, subject, options) {
        return explorer.selectSubject(owner, facet, subject, {
          ...options,
          history: "none",
        });
      },
      subjectFacet: route.subjectFacet,
      subjectRef: route.subject,
    });
    if (route.subject && restored === false && selectedOwner) {
      explorer.selectAddress(routed.address, { history: "replace" });
    }
    setLoadState("ready");
  } catch (error) {
    setLoadState(
      "error",
      error instanceof Error ? error.message : t("当前命令 URL 无效。", "The command URL is invalid."),
    );
  }
});

startApplication();
