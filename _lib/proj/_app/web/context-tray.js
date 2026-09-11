import { readCommandRun, startCommandRun } from "./command-run-client.js";
import { createContextProjection } from "./context-projection-model.js";
import { renderContextFields } from "./context-projection.js";
import {
  contextAddInvocation,
  createPinnedContextRecord,
  parsePinnedContextRecord,
  PINNED_CONTEXT_SCHEMA,
  pinnedContextRef,
} from "./context-tray-model.js";
import { t } from "./i18n.js";
import { isRuntimeGenerationCode } from "./runtime-generation.js";

const TERMINAL_STATES = new Set(["exited", "canceled", "failed"]);

async function completeOperation(route, arguments_) {
  let snapshot = await startCommandRun(route, arguments_);
  while (!TERMINAL_STATES.has(snapshot.state)) {
    await new Promise((resolve) => setTimeout(resolve, 100));
    snapshot = await readCommandRun(snapshot.id, snapshot.nextCursor);
  }
  if (snapshot.state !== "exited" || snapshot.exitCode !== 0) {
    throw new Error(snapshot.error || `${route} exited with code ${snapshot.exitCode ?? "unknown"}.`);
  }
  return snapshot;
}

export function createContextTrayView(elements, options) {
  const executeOperation = options.executeOperation ?? completeOperation;
  const loadDocument = options.loadDocument;
  const loadResource = options.loadResource;
  const onPinnedChange = options.onPinnedChange ?? (() => {});
  const onRuntimeUpdateRequired = options.onRuntimeUpdateRequired ?? (() => {});
  const renderFields = options.renderFields ?? renderContextFields;
  const storage = options.storage;
  let currentCommand = null;
  let pinnedDocument = null;
  let pinnedRecord = null;
  let pinnedResource = null;
  let version = 0;
  let working = false;

  const fields = {
    commandEmpty: elements.contextTrayCommandEmpty,
    commands: elements.contextTrayCommands,
    notes: elements.contextTrayNotes,
    notesEmpty: elements.contextTrayNotesEmpty,
    prompt: elements.contextTrayPrompt,
    promptEmpty: elements.contextTrayPromptEmpty,
  };

  function readStorage() {
    try {
      return parsePinnedContextRecord(storage.getItem(PINNED_CONTEXT_SCHEMA));
    } catch {
      try { storage.removeItem(PINNED_CONTEXT_SCHEMA); } catch {}
      return null;
    }
  }

  function writeStorage(record) {
    try { storage.setItem(PINNED_CONTEXT_SCHEMA, JSON.stringify(record)); } catch {}
  }

  function removeStorage() {
    try { storage.removeItem(PINNED_CONTEXT_SCHEMA); } catch {}
  }

  function setFeedback(message = "", state = "") {
    elements.contextTrayFeedback.textContent = message;
    elements.contextTrayFeedback.dataset.state = state;
  }

  function updateAdd() {
    const invocation = contextAddInvocation(pinnedResource, currentCommand, pinnedDocument);
    const present = invocation?.state === "present";
    elements.contextTrayCommand.textContent = currentCommand?.address ?? "—";
    elements.contextTrayAdd.disabled = working || invocation?.state !== "available";
    elements.contextTrayAddLabel.hidden = present;
    elements.contextTrayPresentLabel.hidden = !present;
    return invocation;
  }

  function render(resource, payload) {
    const document_ = createContextProjection(payload, resource.identity.id);
    pinnedDocument = document_;
    pinnedResource = resource;
    elements.contextTrayTitle.textContent = resource.label;
    elements.contextTrayRef.textContent = resource.route;
    elements.contextTraySummary.textContent = resource.summary;
    renderFields(fields, document_);
    elements.contextTray.hidden = false;
    updateAdd();
    onPinnedChange(resource.route);
  }

  function clear({ removeStored = true } = {}) {
    pinnedDocument = null;
    pinnedRecord = null;
    pinnedResource = null;
    elements.contextTray.hidden = true;
    setFeedback();
    if (removeStored) {
      removeStorage();
    }
    onPinnedChange(null);
  }

  function unpin() {
    version += 1;
    clear();
  }

  async function resolveRecord(record, expectedVersion) {
    const resource = await loadResource(record);
    if (expectedVersion !== version) {
      return false;
    }
    if (!resource) {
      clear();
      return false;
    }
    const payload = await loadDocument(resource);
    if (expectedVersion !== version) {
      return false;
    }
    pinnedRecord = record;
    render(resource, payload);
    return true;
  }

  async function pin(resource, payload) {
    const record = createPinnedContextRecord(resource);
    version += 1;
    pinnedRecord = record;
    writeStorage(record);
    setFeedback();
    render(resource, payload);
  }

  async function restore() {
    const record = readStorage();
    if (!record) {
      clear();
      return false;
    }
    const expectedVersion = ++version;
    pinnedRecord = record;
    try {
      return await resolveRecord(record, expectedVersion);
    } catch {
      if (expectedVersion === version) {
        clear();
      }
      return false;
    }
  }

  async function refresh() {
    if (!pinnedRecord) {
      return false;
    }
    const expectedVersion = ++version;
    try {
      return await resolveRecord(pinnedRecord, expectedVersion);
    } catch (error) {
      if (expectedVersion === version) {
        setFeedback(
          error instanceof Error ? error.message : t(
            "刷新固定 Context 时发生未知错误。",
            "An unknown error occurred while refreshing the pinned Context.",
          ),
          "error",
        );
      }
      return false;
    }
  }

  function selectCommand(command) {
    currentCommand = command?.address ? command : null;
    updateAdd();
  }

  async function addCurrentCommand() {
    const invocation = updateAdd();
    if (invocation?.state !== "available") {
      return false;
    }
    const addedAddress = currentCommand.address;
    const targetRecord = pinnedRecord;
    working = true;
    setFeedback(t("正在加入命令…", "Adding command…"), "working");
    updateAdd();
    try {
      await executeOperation(invocation.route, invocation.arguments);
      if (pinnedRecord !== targetRecord) {
        return true;
      }
      await refresh();
      if (pinnedRecord !== targetRecord) {
        return true;
      }
      setFeedback(t(
        `已加入 ${addedAddress}。`,
        `Added ${addedAddress}.`,
      ), "success");
      return true;
    } catch (error) {
      if (pinnedRecord !== targetRecord) {
        return false;
      }
      if (isRuntimeGenerationCode(error?.code)) {
        onRuntimeUpdateRequired(error);
      }
      setFeedback(
        error instanceof Error ? error.message : t(
          "加入命令时发生未知错误。",
          "An unknown error occurred while adding the command.",
        ),
        "error",
      );
      return false;
    } finally {
      working = false;
      updateAdd();
    }
  }

  function operationCompleted(address) {
    if (pinnedResource?.facets.some((facet) => facet.resolver?.address === address)) {
      void refresh();
    }
  }

  elements.contextTrayAdd.addEventListener("click", () => { void addCurrentCommand(); });
  elements.contextTrayUnpin.addEventListener("click", unpin);
  clear({ removeStored: false });

  return {
    addCurrentCommand,
    operationCompleted,
    pin,
    pinnedRef() { return pinnedRecord ? pinnedContextRef(pinnedRecord) : null; },
    refresh,
    restore,
    selectCommand,
    unpin,
  };
}
