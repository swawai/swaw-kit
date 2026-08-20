import { t } from "./i18n.js";
import {
  createEntryInstance,
  inspectEntryInstance,
  migrateEntryInstance,
  readEntryInventory,
} from "./entry-manager-client.js";
import { previewEntryPaths } from "./entry-manager-model.js";

const INSPECT_DELAY_MS = 250;

function statusLabel(status) {
  return {
    available: t("可创建", "Available to create"),
    ready: t("已就绪", "Ready"),
    legacyMigrationRequired: t("需要显式迁移", "Explicit migration required"),
    incomplete: t("状态不完整", "Incomplete"),
    conflict: t("存在冲突", "Conflict"),
  }[status] ?? t("等待检查", "Waiting for inspection");
}

export function createEntryManagerView(
  elements,
  {
    fetchImpl = fetch,
    documentImpl = document,
    schedule = (callback) => globalThis.setTimeout(callback, INSPECT_DELAY_MS),
    cancelSchedule = (token) => globalThis.clearTimeout(token),
  } = {},
) {
  let active = false;
  let inventory = null;
  let selectedState = null;
  let busy = false;
  let scheduledInspection = null;
  let inspectionRevision = 0;

  function showSurface(manager) {
    elements.entryManagerPanel.hidden = !manager;
    elements.catalogCanvas.hidden = manager;
    elements.entryManagerTab.dataset.active = String(manager);
    elements.entryConsoleTab.dataset.active = String(!manager);
    elements.entryManagerTab.setAttribute("aria-pressed", String(manager));
    elements.entryConsoleTab.setAttribute("aria-pressed", String(!manager));
  }

  function renderActions() {
    elements.entryManagerCreate.disabled = busy || selectedState?.status !== "available";
    elements.entryManagerMigrate.disabled = busy
      || selectedState?.status !== "legacyMigrationRequired";
    elements.entryManagerRefresh.disabled = busy;
    elements.entryManagerInput.disabled = busy;
    elements.entryManagerCreate.dataset.busy = String(busy);
    elements.entryManagerMigrate.dataset.busy = String(busy);
  }

  function renderPaths() {
    const paths = previewEntryPaths(
      inventory?.swawkitHome ?? "",
      elements.entryManagerInput.value,
    );
    elements.entryManagerEntryFile.textContent = paths?.entryFile ?? "—";
    elements.entryManagerDataRoot.textContent = paths?.dataRoot ?? "—";
    return paths;
  }

  function renderState(state) {
    selectedState = state;
    elements.entryManagerState.dataset.status = state?.status ?? "idle";
    elements.entryManagerState.textContent = statusLabel(state?.status);
    const issues = state?.issues ?? [];
    elements.entryManagerIssues.replaceChildren(...issues.map((issue) => {
      const item = documentImpl.createElement("li");
      item.textContent = issue;
      return item;
    }));
    elements.entryManagerIssues.hidden = issues.length === 0;
    renderActions();
  }

  function renderInventory() {
    const entries = inventory?.entries ?? [];
    elements.entryManagerInventory.replaceChildren(...entries.map((entry) => {
      const item = documentImpl.createElement("li");
      const heading = documentImpl.createElement("div");
      const name = documentImpl.createElement("strong");
      const status = documentImpl.createElement("span");
      const path = documentImpl.createElement("code");
      name.textContent = entry.entryName;
      status.textContent = statusLabel(entry.status);
      status.dataset.status = entry.status;
      path.textContent = entry.entryFile;
      heading.append(name, status);
      item.append(heading, path);
      item.dataset.status = entry.status;
      return item;
    }));
    elements.entryManagerInventoryEmpty.hidden = entries.length !== 0;
  }

  function feedback(message, state = "") {
    elements.entryManagerFeedback.textContent = message;
    elements.entryManagerFeedback.dataset.state = state;
  }

  async function loadInventory() {
    inventory = await readEntryInventory(fetchImpl);
    elements.entryManagerHome.textContent = inventory.swawkitHome;
    renderInventory();
    renderPaths();
    return inventory;
  }

  async function inspect() {
    const entryName = elements.entryManagerInput.value;
    if (!renderPaths()) {
      inspectionRevision += 1;
      renderState(null);
      feedback(
        entryName.length === 0
          ? t("输入 Entry 名称以检查目标路径。", "Enter an Entry name to inspect its target paths.")
          : t(
            "Entry 名称须以小写字母开头，只含小写字母、数字或单个连字符，最多 48 个字符，且不能是 swawkit。",
            "The Entry name must start with a lowercase letter, use lowercase letters, digits, or single hyphens, be at most 48 characters, and not be swawkit.",
          ),
        entryName.length === 0 ? "" : "error",
      );
      return null;
    }
    const revision = ++inspectionRevision;
    feedback(t("正在检查 Entry 状态…", "Inspecting Entry state…"));
    try {
      const document = await inspectEntryInstance(entryName, fetchImpl);
      if (revision !== inspectionRevision || entryName !== elements.entryManagerInput.value) {
        return null;
      }
      renderState(document.entry);
      feedback("");
      return document.entry;
    } catch (error) {
      if (revision === inspectionRevision) {
        renderState(null);
        feedback(
          error instanceof Error ? error.message : t("Entry 检查失败。", "Entry inspection failed."),
          "error",
        );
      }
      return null;
    }
  }

  function scheduleInspection() {
    if (scheduledInspection !== null) cancelSchedule(scheduledInspection);
    inspectionRevision += 1;
    renderState(null);
    renderPaths();
    if (elements.entryManagerInput.value.length === 0) {
      feedback(t("输入 Entry 名称以检查目标路径。", "Enter an Entry name to inspect its target paths."));
      scheduledInspection = null;
      return;
    }
    feedback(t("等待检查…", "Waiting to inspect…"));
    scheduledInspection = schedule(() => {
      scheduledInspection = null;
      void inspect();
    });
  }

  async function mutate(operation) {
    const entryName = elements.entryManagerInput.value;
    const allowed = operation === "create"
      ? selectedState?.status === "available"
      : selectedState?.status === "legacyMigrationRequired";
    if (busy || !allowed) return null;
    busy = true;
    renderActions();
    feedback(
      operation === "create"
        ? t("正在创建 Entry…", "Creating Entry…")
        : t("正在迁移 Entry…", "Migrating Entry…"),
    );
    try {
      const document = operation === "create"
        ? await createEntryInstance(entryName, fetchImpl)
        : await migrateEntryInstance(entryName, fetchImpl);
      renderState(document.entry);
      feedback(document.changed
        ? operation === "create"
          ? t("Entry 已创建。", "Entry created.")
          : t("Entry 已迁移。", "Entry migrated.")
        : t("Entry 已经处于目标状态。", "Entry was already in the requested state."));
      try {
        await loadInventory();
      } catch (error) {
        feedback(t(
          `操作成功，但刷新清单失败：${error instanceof Error ? error.message : ""}`,
          `The operation succeeded, but inventory refresh failed: ${error instanceof Error ? error.message : ""}`,
        ), "error");
      }
      return document;
    } catch (error) {
      feedback(
        error instanceof Error ? error.message : t("Entry 操作失败。", "Entry operation failed."),
        "error",
      );
      return null;
    } finally {
      busy = false;
      renderActions();
    }
  }

  async function refresh() {
    if (busy) return;
    busy = true;
    renderActions();
    feedback(t("正在刷新 Entry 清单…", "Refreshing Entry inventory…"));
    try {
      await loadInventory();
      await inspect();
    } catch (error) {
      feedback(
        error instanceof Error ? error.message : t("Entry 清单刷新失败。", "Entry inventory refresh failed."),
        "error",
      );
    } finally {
      busy = false;
      renderActions();
    }
  }

  async function activate(entryName) {
    if (entryName !== "swawkit") {
      active = false;
      elements.entryManagerNavigation.hidden = true;
      elements.entryManagerPanel.hidden = true;
      elements.catalogCanvas.hidden = false;
      delete elements.workspace.dataset.entryManager;
      return false;
    }
    const firstActivation = !active;
    active = true;
    elements.workspace.dataset.entryManager = "true";
    elements.entryManagerNavigation.hidden = false;
    if (firstActivation) showSurface(true);
    try {
      await loadInventory();
      feedback(t("输入 Entry 名称以开始。", "Enter an Entry name to begin."));
    } catch (error) {
      feedback(
        error instanceof Error ? error.message : t("Entry 清单不可用。", "Entry inventory is unavailable."),
        "error",
      );
    }
    return true;
  }

  elements.entryManagerForm.addEventListener("submit", (event) => {
    event.preventDefault();
    if (scheduledInspection !== null) cancelSchedule(scheduledInspection);
    scheduledInspection = null;
    void inspect();
  });
  elements.entryManagerInput.addEventListener("input", scheduleInspection);
  elements.entryManagerCreate.addEventListener("click", () => void mutate("create"));
  elements.entryManagerMigrate.addEventListener("click", () => void mutate("migrate"));
  elements.entryManagerRefresh.addEventListener("click", () => void refresh());
  elements.entryManagerTab.addEventListener("click", () => showSurface(true));
  elements.entryConsoleTab.addEventListener("click", () => showSurface(false));

  renderState(null);
  return {
    activate,
    create: () => mutate("create"),
    inspect,
    migrate: () => mutate("migrate"),
    refresh,
    showManager: () => showSurface(true),
    showConsole: () => showSurface(false),
  };
}
