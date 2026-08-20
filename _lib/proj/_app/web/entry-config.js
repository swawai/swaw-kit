import { t } from "./i18n.js";
import {
  RuntimeGenerationError,
  runtimeGenerationMessage,
} from "./runtime-generation.js";

const CONFIG_PROTOCOL = "swawkit.entry-config-state/v1";
const CONFIG_SCHEMA = "swawkit.entry-config/v1";
const SETTER_HANDLER = "entry.config.set";
const LANGUAGE_ADDRESS = ".entry/language";
const PROJECT_ROOT_ADDRESS = ".entry/project/root";
const CONFIG_FIELDS = [
  "protocol",
  "revision",
  "status",
  "path",
  "config",
  "settings",
  "resolvedProjectRoot",
  "error",
];

export class EntryConfigConflictError extends Error {}

function hasExactFields(value, fields) {
  const actual = Object.keys(value).sort();
  const expected = [...fields].sort();
  return actual.length === expected.length
    && actual.every((field, index) => field === expected[index]);
}

function requireObject(value, name, fields) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`Invalid Entry Config protocol: ${name} must be an object.`);
  }
  if (!hasExactFields(value, fields)) {
    throw new Error(`Invalid Entry Config protocol: ${name} has an unexpected shape.`);
  }
  return value;
}

function optionalString(value, name) {
  if (value !== null && (typeof value !== "string" || value.length === 0)) {
    throw new Error(`Invalid Entry Config protocol: ${name} must be null or a non-empty string.`);
  }
  return value;
}

export function normalizeEntryConfigDocument(value) {
  const document = requireObject(value, "document", CONFIG_FIELDS);
  if (document.protocol !== CONFIG_PROTOCOL) {
    throw new Error(`Invalid Entry Config protocol: protocol must be ${CONFIG_PROTOCOL}.`);
  }
  for (const field of ["revision", "path"]) {
    if (typeof document[field] !== "string" || document[field].length === 0) {
      throw new Error(`Invalid Entry Config protocol: ${field} must be a non-empty string.`);
    }
  }
  if (!["default", "ready", "bindingUnavailable", "invalid"].includes(document.status)) {
    throw new Error("Invalid Entry Config protocol: status is unsupported.");
  }

  const config = requireObject(
    document.config,
    "config",
    ["schema", "language", "projectRoot"],
  );
  if (config.schema !== CONFIG_SCHEMA) {
    throw new Error(`Invalid Entry Config protocol: config.schema must be ${CONFIG_SCHEMA}.`);
  }
  if (!["zh-CN", "en"].includes(config.language)) {
    throw new Error("Invalid Entry Config protocol: config.language must be zh-CN or en.");
  }
  optionalString(config.projectRoot, "config.projectRoot");

  const settings = requireObject(
    document.settings,
    "settings",
    [LANGUAGE_ADDRESS, PROJECT_ROOT_ADDRESS],
  );
  if (settings[LANGUAGE_ADDRESS] !== config.language) {
    throw new Error("Invalid Entry Config protocol: language setting does not match config.");
  }
  optionalString(settings[PROJECT_ROOT_ADDRESS], `settings.${PROJECT_ROOT_ADDRESS}`);
  if (settings[PROJECT_ROOT_ADDRESS] !== config.projectRoot) {
    throw new Error("Invalid Entry Config protocol: project root setting does not match config.");
  }

  optionalString(document.resolvedProjectRoot, "resolvedProjectRoot");
  optionalString(document.error, "error");
  const failed = ["bindingUnavailable", "invalid"].includes(document.status);
  if (failed !== (document.error !== null)) {
    throw new Error("Invalid Entry Config protocol: error does not match status.");
  }
  if (document.status === "bindingUnavailable" && document.resolvedProjectRoot !== null) {
    throw new Error("Invalid Entry Config protocol: unavailable binding cannot be resolved.");
  }
  if (
    document.status === "bindingUnavailable"
    && config.projectRoot === null
  ) {
    throw new Error("Invalid Entry Config protocol: unavailable binding requires projectRoot.");
  }
  if (
    document.status === "ready"
    && (config.projectRoot === null) !== (document.resolvedProjectRoot === null)
  ) {
    throw new Error("Invalid Entry Config protocol: ready binding resolution is inconsistent.");
  }
  if (
    ["default", "invalid"].includes(document.status)
    && (config.projectRoot !== null || document.resolvedProjectRoot !== null)
  ) {
    throw new Error("Invalid Entry Config protocol: unbound state contains a project root.");
  }
  return document;
}

export async function putEntryConfigSetting(
  address,
  value,
  revision,
  fetchConfig = fetch,
) {
  const response = await fetchConfig(
    `/api/v2/entry-config/settings/${encodeURIComponent(address)}`,
    {
      method: "PUT",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        "If-Match": `"${revision}"`,
      },
      body: JSON.stringify({ value }),
    },
  );
  const document = await response.json();
  const generationMessage = runtimeGenerationMessage(document?.code);
  if (generationMessage) {
    throw new RuntimeGenerationError(
      generationMessage,
      response.status,
      document.code,
    );
  }
  if (response.status === 409) {
    throw new EntryConfigConflictError(document.error);
  }
  if (!response.ok) {
    throw new Error(document.error || t(
      `Host 返回 HTTP ${response.status}`,
      `Host returned HTTP ${response.status}`,
    ));
  }
  return normalizeEntryConfigDocument(document);
}

export function createEntryConfigView(
  elements,
  {
    fetchImpl = fetch,
    onConfigChanged,
    onRuntimeUpdateRequired = () => {},
  },
) {
  let currentDocument = null;
  let currentCommand = null;
  let saveInFlight = false;

  function renderState() {
    if (!currentDocument) {
      elements.configState.dataset.state = "loading";
      elements.configState.textContent = t("正在读取 Entry Config…", "Loading Entry Config…");
      return;
    }
    elements.configState.dataset.state = currentDocument.status;
    const messages = {
      default: t("正在使用默认语言，尚未绑定项目", "Using the default language with no project binding"),
      ready: t("Entry Config 已生效", "Entry Config is active"),
      bindingUnavailable: currentDocument.error,
      invalid: currentDocument.error,
    };
    elements.configState.textContent = messages[currentDocument.status];
  }

  function render(command) {
    if (command?.handler !== SETTER_HANDLER) {
      currentCommand = null;
      return false;
    }
    currentCommand = command;
    const address = command.address;
    const label = address.split("/").at(-1).replace(/^\.+/, "");
    const known = currentDocument && Object.hasOwn(currentDocument.settings, address);
    elements.entryConfigTitle.textContent = label;
    elements.entryConfigSummary.textContent = command.summary
      || t("原子修改这个 Entry Config 设置。", "Atomically update this Entry Config setting.");
    elements.configSettingAddress.textContent = address;
    elements.configValue.value = known ? currentDocument.settings[address] ?? "" : "";
    elements.configValue.disabled = !known;
    elements.configSaveButton.disabled = !known || saveInFlight;
    elements.configFeedback.textContent = known || !currentDocument
      ? ""
      : t("Catalog 声明了配置中不存在的设置。", "The Catalog declares an unknown setting.");
    elements.configFeedback.dataset.state = known || !currentDocument ? "" : "error";
    renderState();
    elements.selectionStatus.textContent = t(
      `已选择命令 ${command.address}`,
      `Selected command ${command.address}`,
    );
    return true;
  }

  function acceptDocument(document) {
    currentDocument = normalizeEntryConfigDocument(document);
    if (currentCommand) {
      render(currentCommand);
    }
    return currentDocument;
  }

  async function loadConfig() {
    currentDocument = null;
    renderState();
    const response = await fetchImpl("/api/v2/entry-config", {
      cache: "no-store",
      headers: { Accept: "application/json" },
    });
    if (!response.ok) {
      throw new Error(t(
        `Host 返回 HTTP ${response.status}`,
        `Host returned HTTP ${response.status}`,
      ));
    }
    return acceptDocument(await response.json());
  }

  async function saveConfig() {
    if (!currentDocument || !currentCommand || saveInFlight) {
      return;
    }
    const command = currentCommand;
    const address = command.address;
    const operationIsCurrent = () => currentCommand?.address === command.address;
    const value = address === PROJECT_ROOT_ADDRESS && elements.configValue.value === ""
      ? null
      : elements.configValue.value;
    saveInFlight = true;
    elements.configSaveButton.disabled = true;
    elements.configFeedback.dataset.state = "";
    elements.configFeedback.textContent = t("正在保存…", "Saving…");
    try {
      const document = await putEntryConfigSetting(
        address,
        value,
        currentDocument.revision,
        fetchImpl,
      );
      acceptDocument(document);
      await onConfigChanged(document);
      if (operationIsCurrent()) {
        elements.configFeedback.textContent = t("设置已保存", "Setting saved");
      }
    } catch (error) {
      let feedback = error;
      if (error instanceof RuntimeGenerationError) {
        onRuntimeUpdateRequired(error);
      } else if (error instanceof EntryConfigConflictError) {
        try {
          const latest = await loadConfig();
          await onConfigChanged(latest);
          if (operationIsCurrent()) {
            elements.configFeedback.textContent = t(
              "配置已被其他进程修改；已载入最新值。",
              "Another process changed the config; the latest value has been loaded.",
            );
          }
          feedback = null;
        } catch {
          feedback = new Error(t(
            "配置已经变化，请重新加载页面后再保存。",
            "The config changed. Reload the page before saving again.",
          ));
        }
      }
      if (feedback && operationIsCurrent()) {
        elements.configFeedback.dataset.state = "error";
        elements.configFeedback.textContent = feedback instanceof Error
          ? feedback.message
          : t("保存设置时发生未知错误。", "An unknown error occurred while saving.");
      }
    } finally {
      saveInFlight = false;
      const known = currentDocument
        && currentCommand
        && Object.hasOwn(currentDocument.settings, currentCommand.address);
      elements.configSaveButton.disabled = !known;
    }
  }

  return { loadConfig, render, saveConfig };
}
