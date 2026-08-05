import { createCatalog } from "./catalog-model.js";
import { createDetailView } from "./detail.js";
import { createExplorerView } from "./explorer.js";
import { createSystemView } from "./system.js";

const elements = {
  actionCount: document.querySelector("#action-count"),
  breadcrumb: document.querySelector("#breadcrumb"),
  catalogCount: document.querySelector("#catalog-count"),
  cliCommand: document.querySelector("#cli-command"),
  commandDetail: document.querySelector("#command-detail"),
  connectionLabel: document.querySelector("#connection-label"),
  connectionStatus: document.querySelector("#connection-status"),
  copyButton: document.querySelector("#copy-button"),
  copyFeedback: document.querySelector("#copy-feedback"),
  copyLabel: document.querySelector("#copy-label"),
  detailAddress: document.querySelector("#detail-address"),
  detailHelp: document.querySelector("#detail-help"),
  detailIssue: document.querySelector("#detail-issue"),
  detailPanel: document.querySelector("#detail-panel"),
  detailSummary: document.querySelector("#detail-summary"),
  entryName: document.querySelector("#entry-name"),
  errorMessage: document.querySelector("#error-message"),
  errorState: document.querySelector("#error-state"),
  explorerFrame: document.querySelector("#explorer-frame"),
  explorerFlow: document.querySelector("#explorer-flow"),
  finderColumns: document.querySelector("#finder-columns"),
  hostAddress: document.querySelector("#host-address"),
  invocationSection: document.querySelector("#invocation-section"),
  issueCard: document.querySelector("#issue-card"),
  kernelCount: document.querySelector("#kernel-count"),
  loadingState: document.querySelector("#loading-state"),
  propertyAddress: document.querySelector("#property-address"),
  propertyEntry: document.querySelector("#property-entry"),
  propertyEntryRow: document.querySelector("#property-entry-row"),
  protocolName: document.querySelector("#protocol-name"),
  profileFeedback: document.querySelector("#profile-feedback"),
  profileForm: document.querySelector("#profile-form"),
  profileResolvedRoot: document.querySelector("#profile-resolved-root"),
  profileSaveButton: document.querySelector("#profile-save-button"),
  profileState: document.querySelector("#profile-state"),
  refreshButton: document.querySelector("#refresh-button"),
  retryButton: document.querySelector("#retry-button"),
  selectionStatus: document.querySelector("#selection-status"),
  systemDetail: document.querySelector("#system-detail"),
  systemOverview: document.querySelector("#system-overview"),
  systemSummary: document.querySelector("#system-summary"),
  systemTitle: document.querySelector("#system-title"),
};

let catalog = null;
const detail = createDetailView(elements);
const system = createSystemView(elements, {
  async onProfileChanged(document, page) {
    explorer.setSetupRequired(!document.requiredComplete);
    await loadCatalog();
    explorer.selectSystemPage(page);
  },
});
const explorer = createExplorerView({
  breadcrumb: elements.breadcrumb,
  columns: elements.finderColumns,
  detailPanel: elements.detailPanel,
  onSelectCommand(command) {
    detail.render(catalog, command);
  },
  onSelectSystem(page) {
    system.render(page);
  },
});

function setLoadState(status, message = "") {
  const loading = status === "loading";
  const failed = status === "error";

  elements.loadingState.hidden = !loading;
  elements.errorState.hidden = !failed;
  elements.explorerFlow.hidden = status !== "ready";
  elements.explorerFrame.setAttribute("aria-busy", String(loading));
  elements.refreshButton.disabled = loading;
  system.setStatus(status);

  if (failed) {
    elements.errorMessage.textContent = message || "无法连接 Host。";
  }
}

async function loadCatalog() {
  setLoadState("loading");
  try {
    const response = await fetch("/api/v1/catalog", {
      cache: "no-store",
      headers: { Accept: "application/json" },
    });
    if (!response.ok) {
      throw new Error(`Host 返回 HTTP ${response.status}`);
    }

    catalog = createCatalog(await response.json());
    system.setCatalog(catalog);
    explorer.setCatalog(catalog);
    setLoadState("ready");
  } catch (error) {
    const message = error instanceof Error
      ? error.message
      : "读取 Catalog 时发生未知错误。";
    setLoadState("error", message);
  }
}

async function loadApplication() {
  setLoadState("loading");
  try {
    const document = await system.loadProfile();
    explorer.setSetupRequired(!document.requiredComplete);
    const response = await fetch("/api/v1/catalog", {
      cache: "no-store",
      headers: { Accept: "application/json" },
    });
    if (!response.ok) {
      throw new Error(`Host 返回 HTTP ${response.status}`);
    }
    catalog = createCatalog(await response.json());
    system.setCatalog(catalog);
    explorer.setCatalog(catalog);
    setLoadState("ready");
  } catch (error) {
    const message = error instanceof Error
      ? error.message
      : "读取控制台状态时发生未知错误。";
    setLoadState("error", message);
  }
}

elements.copyButton.addEventListener("click", detail.copyInvocation);
elements.profileForm.addEventListener("submit", (event) => {
  event.preventDefault();
  system.saveProfile();
});
elements.finderColumns.addEventListener("keydown", explorer.handleKeyboard);
elements.refreshButton.addEventListener("click", loadCatalog);
elements.retryButton.addEventListener("click", loadCatalog);

loadApplication();
