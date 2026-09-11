import { createCatalog } from "./catalog-model.js";
import {
  createResourceFacetView,
  defaultCommandFacet,
} from "./resource-facet.js";
import { createCommandRunView } from "./command-run.js";
import { createContextProjectionRenderer } from "./context-projection.js";
import { createContextTrayView } from "./context-tray.js";
import { createDetailView } from "./detail.js";
import { createDocumentProjectionView } from "./document-projection.js";
import { createExplorerView } from "./explorer.js";
import { createEntryConfigView } from "./entry-config.js";
import { setLanguage, t } from "./i18n.js";
import { createCommandCheckProjectionRenderer } from "./command-check-projection.js";
import { createRuntimeControlView } from "./runtime-control.js";
import { createRunProjectionRenderer } from "./run-projection.js";
import { createEntryManagerView } from "./entry-manager-view.js";
import {
  createViewBundleLoader,
  FacetResolutionError,
  resolveCollectionView,
  resolveDocumentFacet,
} from "./facet-resolution-client.js";
import { isRuntimeGenerationCode } from "./runtime-generation.js";
import { commandRef } from "./command-identity.js";
import { commandFacetRoute } from "./resource-route.js";
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
  commandCheckDependencies: document.querySelector("#command-check-dependencies"),
  commandCheckDiagnostic: document.querySelector("#command-check-diagnostic"),
  commandCheckMeta: document.querySelector("#command-check-meta"),
  commandCheckPane: document.querySelector("#command-check-pane"),
  commandCheckState: document.querySelector("#command-check-state"),
  commandCheckTitle: document.querySelector("#command-check-title"),
  propertyAddress: document.querySelector("#property-address"),
  propertyEntry: document.querySelector("#property-entry"),
  propertyEntryRow: document.querySelector("#property-entry-row"),
  configFeedback: document.querySelector("#config-feedback"),
  configForm: document.querySelector("#config-form"),
  configSaveButton: document.querySelector("#config-save-button"),
  configState: document.querySelector("#config-state"),
  configValue: document.querySelector("#config-value"),
  configSettingAddress: document.querySelector("#config-setting-address"),
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
  entryConfigDetail: document.querySelector("#entry-config-detail"),
  entryConfigSummary: document.querySelector("#entry-config-summary"),
  entryConfigTitle: document.querySelector("#entry-config-title"),
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
    if (selectedResource) {
      void refreshSelectedResourceList();
    }
    contextTray?.operationCompleted(snapshot.address);
  },
  onRuntimeUpdateRequired() {
    void runtimeControl?.load();
  },
});
const commandFacet = createResourceFacetView(elements, {
  defaultFacet: defaultCommandFacet,
  fallbackRenderer: "overview",
});
const resourceFacet = createResourceFacetView();
const contextProjection = createContextProjectionRenderer(elements, {
  onPin(resource, document) {
    void contextTray?.pin(resource, document);
  },
});
const documentProjection = createDocumentProjectionView(elements, {
  renderers: [
    createCommandCheckProjectionRenderer(elements),
    contextProjection,
    createRunProjectionRenderer(elements),
  ],
  resolveDocument(resource, facet) {
    return resolveRuntimeDocument(resource, facet);
  },
});
let selectedResource = null;
let selectedResourceFacet = null;
let runtimeControl = null;

async function resolveRuntime(task) {
  try {
    return await task;
  } catch (error) {
    if (
      error instanceof FacetResolutionError
      && isRuntimeGenerationCode(error.code)
    ) {
      void runtimeControl?.load();
    }
    throw error;
  }
}

function resolveRuntimeDocument(resource, facet) {
  return resolveRuntime(resolveDocumentFacet(resource, facet));
}

function resolveRuntimeCollectionView(command, facet) {
  return resolveRuntime(resolveCollectionView(catalog, command, facet));
}

const entryConfig = createEntryConfigView(elements, {
  async onConfigChanged(document) {
    setLanguage(document.config.language);
    void runtimeControl?.load();
    await loadCatalog();
  },
  onRuntimeUpdateRequired() {
    void runtimeControl?.load();
  },
});
const explorer = createExplorerView({
  columns: elements.finderColumns,
  detailPanel: elements.detailPanel,
  getCommandFacets(command) {
    return commandFacet.items(command);
  },
  getResourceFacets(resource) {
    return resourceFacet.items(resource);
  },
  onResolveCollection(owner, facet) {
    void loadResourceList(owner, facet).catch(() => {});
  },
  onSelectCommand(command, options = {}) {
    selectedResource = null;
    selectedResourceFacet = null;
    resourceFacet.select(null);
    contextTray?.selectCommand(command);
    entryConfig.render(command);
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
      route: runResolver
        ? commandFacetRoute(commandRef(command), selection.facet.id)
        : null,
    });
    if (showsDocumentProjection) {
      elements.commandDetail.hidden = true;
    }
    elements.detailPanel.dataset.view = selection.facet?.renderer ?? "";
    elements.detailPanel.hidden = selection.facet?.kind === "collection";
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
  onSelectResource(resource, options = {}) {
    selectedResource = resource;
    const owner = catalog.commandByAddress.get(resource.owner);
    entryConfig.render(null);
    runtimeControl?.select(null);
    contextTray?.selectCommand(null);
    commandFacet.select(owner, { facet: resource.collectionFacet });
    const selection = resourceFacet.select(resource, { facet: options.facet });
    selectedResourceFacet = selection.selectedFacet;
    const resolver = selection.facet?.resolver ?? null;
    const runCommand = selection.facet?.renderer === "run" && resolver?.type === "command"
      ? catalog.commandByAddress.get(resolver.address) ?? null
      : null;
    commandRun.select(runCommand, {
      acceptsTail: resolver?.acceptsTail ?? false,
      arguments: resolver?.arguments ?? [],
      confirmation: resolver?.confirmation ?? null,
      key: resolver ? `${resource.route}#${selection.facet.id}` : null,
      label: selection.facet?.label ?? null,
      route: resolver ? `${resource.route}/${selection.facet.id}` : null,
    });
    const runView = selection.facet?.renderer === "run";
    const showsDocumentProjection = documentProjection.select(resource, selection.facet);
    elements.commandWorkspace.hidden = !(runView || showsDocumentProjection);
    elements.commandRunPane.hidden = !runView;
    elements.detailPanel.dataset.view = selection.facet?.renderer ?? "";
    elements.detailPanel.hidden = false;
    elements.selectionStatus.textContent = t(
      `已选择对象 ${resource.route}`,
      `Selected resource ${resource.route}`,
    );
    updateCommandPath(
      window.history,
      window.location,
      owner,
      {
        defaultResourceFacet: selection.defaultFacet,
        facet: resource.collectionFacet,
        mode: options.history ?? "none",
        resource: resource.selector,
        resourceFacet: selection.selectedFacet,
      },
    );
  },
});
const viewBundleLoader = createViewBundleLoader({
  onError(owner, facet, error) {
    explorer.setCollectionViewError(
      owner,
      facet,
      error instanceof Error ? error.message : "Cannot resolve Resource collection.",
    );
  },
  onLoading(owner, facet) {
    explorer.setCollectionViewLoading(owner, facet);
  },
  onResolved(bundle) {
    explorer.setCollectionView(bundle);
  },
  async resolveViewBundle(owner, facet) {
    const command = catalog.commandByAddress.get(owner);
    const selectedFacet = command?.facets.find((candidate) => candidate.id === facet);
    if (!command || selectedFacet?.kind !== "collection") {
      throw new Error(`Cannot resolve missing collection Facet ${owner}#${facet}.`);
    }
    return resolveRuntimeCollectionView(command, selectedFacet);
  },
});
contextTray = createContextTrayView(elements, {
  async loadDocument(resource) {
    const overview = resource.facets.find((facet) => (
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
    return resolveRuntimeDocument(resource, overview);
  },
  async loadResource(record) {
    const owner = record.source.owner.address;
    const list = await loadResourceList(owner, record.source.facet);
    return list?.resourceBySelector.get(record.source.selector) ?? null;
  },
  onPinnedChange(reference) {
    contextProjection.setPinnedRef(reference);
  },
  onRuntimeUpdateRequired() {
    void runtimeControl?.load();
  },
  storage: window.sessionStorage,
});
runtimeControl = createRuntimeControlView(elements, {
  onRuntimeState(state) {
    explorer.setCommandState(".runtime", state);
  },
  onRuntimeUpdateRequired() {
    void runtimeControl?.load();
  },
});
const entryManager = createEntryManagerView(elements, {
  onRuntimeUpdateRequired() {
    void runtimeControl?.load();
  },
});

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

async function loadResourceList(owner, facet) {
  return (await viewBundleLoader.load(owner, facet))?.resourceList ?? null;
}

async function refreshSelectedResourceList() {
  const selectedRoute = selectedResource?.route ?? null;
  const selectedSelector = selectedResource?.selector ?? null;
  const owner = selectedResource?.owner ?? null;
  const facet = selectedResource?.collectionFacet ?? null;
  const selectedFacet = selectedResourceFacet;
  if (!owner || !facet) {
    return;
  }
  try {
    const collection = await loadResourceList(owner, facet);
    if (
      selectedRoute
      && selectedResource?.route === selectedRoute
      && collection?.resourceByRoute.has(selectedRoute)
    ) {
      explorer.selectResource(owner, facet, selectedSelector, {
        history: "replace",
        facet: selectedFacet,
      });
    }
  } catch (error) {
    elements.commandRunFeedback.textContent = error instanceof Error
      ? error.message
      : t("刷新 Resource 集合时发生未知错误。", "An unknown error occurred while refreshing Resources.");
    elements.commandRunFeedback.dataset.state = "error";
  }
}

async function applyCatalogRoute(mode = "replace") {
  const routed = commandAtPath(catalog, window.location.pathname);
  const route = parseCommandSelection(window.location.search);
  if (route.resource && !routed) {
    throw new Error(t("Resource URL 缺少命令所有者。", "A Resource URL requires its command owner."));
  }
  await restoreCommandSelection({
    collectionFacet: route.facet,
    loadResourceList,
    ownerAddress: routed?.address ?? null,
    selectOwner() {
      explorer.setCatalog(catalog, {
        address: routed?.address,
        history: mode,
        facet: route.facet,
      });
      return true;
    },
    selectResource(owner, facet, resource, options) {
      return explorer.selectResource(owner, facet, resource, {
        ...options,
        history: mode,
      });
    },
    resourceFacet: route.resourceFacet,
    resourceSelector: route.resource,
  });
}

function replaceCatalog(document) {
  const nextCatalog = createCatalog(document);
  viewBundleLoader.reset();
  catalog = nextCatalog;
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

    replaceCatalog(await response.json());
    await entryConfig.loadConfig();
    await applyCatalogRoute();
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
    const document = await entryConfig.loadConfig();
    setLanguage(document.config.language);
    void commandRun.restore();
    void runtimeControl.load();
    const response = await fetch("/api/v2/catalog", {
      cache: "no-store",
      headers: { Accept: "application/json" },
    });
    if (!response.ok) {
      throw new Error(t(`Host 返回 HTTP ${response.status}`, `Host returned HTTP ${response.status}`));
    }
    replaceCatalog(await response.json());
    await applyCatalogRoute();
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
elements.configForm.addEventListener("submit", (event) => {
  event.preventDefault();
  entryConfig.saveConfig();
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
    if (route.resource && !routed) {
      throw new Error(t("Resource URL 缺少命令所有者。", "A Resource URL requires its command owner."));
    }
    let selectedOwner = false;
    const restored = await restoreCommandSelection({
      collectionFacet: route.facet,
      loadResourceList,
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
      selectResource(owner, facet, resource, options) {
        return explorer.selectResource(owner, facet, resource, {
          ...options,
          history: "none",
        });
      },
      resourceFacet: route.resourceFacet,
      resourceSelector: route.resource,
    });
    if (route.resource && restored === false && selectedOwner) {
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
