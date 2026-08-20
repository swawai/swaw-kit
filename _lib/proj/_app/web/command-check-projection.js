import { t } from "./i18n.js";
import {
  COMMAND_CHECK_PROTOCOL,
  createCommandCheckProjection,
} from "./command-check-projection-model.js";
import { commandPath } from "./navigation.js";

export function createCommandCheckProjectionRenderer(elements, options = {}) {
  const documentObject = options.document ?? globalThis.document;

  function emptyItem(text) {
    const item = documentObject.createElement("li");
    item.className = "command-check-empty";
    item.textContent = text;
    return item;
  }

  function detail(parent, text) {
    if (!text) {
      return;
    }
    const value = documentObject.createElement("span");
    value.className = "command-check-item-detail";
    value.textContent = text;
    parent.append(value);
  }

  function appendDependency(list, dependency) {
    const row = documentObject.createElement("li");
    const heading = documentObject.createElement("div");
    const marker = documentObject.createElement("span");
    const name = documentObject.createElement("code");
    row.className = "command-check-item";
    row.dataset.state = dependency.ready ? "ready" : "blocked";
    heading.className = "command-check-item-heading";
    marker.className = "command-check-marker";
    marker.textContent = dependency.ready ? "✓" : "!";
    name.textContent = `${dependency.provider}#${dependency.export}`;
    heading.append(marker, name);
    row.append(heading);
    detail(row, dependency.message);
    if (dependency.checker) {
      const action = documentObject.createElement("span");
      const link = documentObject.createElement("a");
      const arguments_ = documentObject.createElement("code");
      const path = commandPath(dependency.checker);
      action.className = "command-check-item-action";
      action.textContent = t("检查：", "Check: ");
      link.href = path;
      link.textContent = path;
      arguments_.textContent = dependency.checker.arguments.length === 0
        ? ""
        : ` ${dependency.checker.arguments.join(" ")}`;
      action.append(link, arguments_);
      row.append(action);
    }
    if (dependency.dependencies.length > 0) {
      const children = documentObject.createElement("ul");
      children.className = "command-check-tree";
      for (const child of dependency.dependencies) {
        appendDependency(children, child);
      }
      row.append(children);
    }
    list.append(row);
  }

  function clear() {
    elements.commandCheckTitle.textContent = "";
    elements.commandCheckMeta.textContent = "";
    elements.commandCheckState.textContent = "";
    elements.commandCheckDiagnostic.textContent = "";
    elements.commandCheckDiagnostic.hidden = true;
    elements.commandCheckDependencies.replaceChildren();
  }

  function hide() {
    elements.commandCheckPane.hidden = true;
    clear();
  }

  function render(subject, payload) {
    const document_ = createCommandCheckProjection(payload, subject);
    const command = document_.command;
    elements.commandCheckTitle.textContent = command.address;
    elements.commandCheckMeta.textContent = [
      command.namespace ? `${command.space}:${command.namespace}` : command.space,
      command.adapter ?? "none",
    ]
      .join(" · ");
    elements.commandCheckState.textContent = document_.ready
      ? t("执行就绪", "Ready to run")
      : t("执行受阻", "Blocked");
    elements.commandCheckState.dataset.state = document_.ready ? "ready" : "blocked";
    elements.commandCheckDiagnostic.textContent = command.diagnostic ?? "";
    elements.commandCheckDiagnostic.hidden = command.diagnostic === null;

    elements.commandCheckDependencies.replaceChildren();
    if (document_.dependencies.length === 0) {
      elements.commandCheckDependencies.append(
        emptyItem(t("无执行依赖", "No execution dependencies")),
      );
    } else {
      for (const dependency of document_.dependencies) {
        appendDependency(elements.commandCheckDependencies, dependency);
      }
    }
    elements.commandCheckPane.hidden = false;
  }

  return { hide, protocol: COMMAND_CHECK_PROTOCOL, render };
}
