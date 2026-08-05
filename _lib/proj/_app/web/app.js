import { createCatalog } from "./catalog-model.js";
import { createDetailView } from "./detail.js";
import { createExplorerView } from "./explorer.js";
import { createEntryProfileView } from "./entry-profile.js";

const elements = {
  breadcrumb: document.querySelector("#breadcrumb"),
  cliCommand: document.querySelector("#cli-command"),
  commandDetail: document.querySelector("#command-detail"),
  copyButton: document.querySelector("#copy-button"),
  copyFeedback: document.querySelector("#copy-feedback"),
  copyLabel: document.querySelector("#copy-label"),
  detailAddress: document.querySelector("#detail-address"),
  detailHelp: document.querySelector("#detail-help"),
  detailIssue: document.querySelector("#detail-issue"),
  detailPanel: document.querySelector("#detail-panel"),
  detailSummary: document.querySelector("#detail-summary"),
  errorMessage: document.querySelector("#error-message"),
  errorState: document.querySelector("#error-state"),
  explorerFrame: document.querySelector("#explorer-frame"),
  explorerFlow: document.querySelector("#explorer-flow"),
  finderColumns: document.querySelector("#finder-columns"),
  invocationSection: document.querySelector("#invocation-section"),
  issueCard: document.querySelector("#issue-card"),
  loadingState: document.querySelector("#loading-state"),
  propertyAddress: document.querySelector("#property-address"),
  propertyEntry: document.querySelector("#property-entry"),
  propertyEntryRow: document.querySelector("#property-entry-row"),
  profileFeedback: document.querySelector("#profile-feedback"),
  profileForm: document.querySelector("#profile-form"),
  profileResolvedRoot: document.querySelector("#profile-resolved-root"),
  profileSaveButton: document.querySelector("#profile-save-button"),
  profileState: document.querySelector("#profile-state"),
  retryButton: document.querySelector("#retry-button"),
  selectionStatus: document.querySelector("#selection-status"),
  entryProfileDetail: document.querySelector("#entry-profile-detail"),
  entryProfileSummary: document.querySelector("#entry-profile-summary"),
  entryProfileTitle: document.querySelector("#entry-profile-title"),
};

let catalog = null;
const detail = createDetailView(elements);
const entryProfile = createEntryProfileView(elements, {
  async onProfileChanged(document, page) {
    explorer.setSetupRequired(!document.requiredComplete);
    await loadCatalog();
    explorer.selectEntryPage(page);
  },
});
const explorer = createExplorerView({
  breadcrumb: elements.breadcrumb,
  columns: elements.finderColumns,
  detailPanel: elements.detailPanel,
  onSelectCommand(command) {
    detail.render(catalog, command);
  },
  onSelectEntryPage(page) {
    entryProfile.render(page);
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
    elements.errorMessage.textContent = message || "无法连接 Host。";
  }
}

async function loadCatalog() {
  setLoadState("loading");
  try {
    const response = await fetch("/api/v2/catalog", {
      cache: "no-store",
      headers: { Accept: "application/json" },
    });
    if (!response.ok) {
      throw new Error(`Host 返回 HTTP ${response.status}`);
    }

    catalog = createCatalog(await response.json());
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
    const document = await entryProfile.loadProfile();
    explorer.setSetupRequired(!document.requiredComplete);
    const response = await fetch("/api/v2/catalog", {
      cache: "no-store",
      headers: { Accept: "application/json" },
    });
    if (!response.ok) {
      throw new Error(`Host 返回 HTTP ${response.status}`);
    }
    catalog = createCatalog(await response.json());
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
  entryProfile.saveProfile();
});
elements.finderColumns.addEventListener("keydown", explorer.handleKeyboard);
elements.retryButton.addEventListener("click", loadApplication);

loadApplication();
