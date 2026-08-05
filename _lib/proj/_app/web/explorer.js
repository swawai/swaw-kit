import {
  childrenOf,
  hasChildren,
  isGroup,
  leafName,
  sortCommands,
} from "./catalog-model.js";
import {
  createSystemNavigationColumn,
  defaultSystemPage,
  isSystemPage,
  systemPageLabel,
} from "./system-navigation.js";

const sourceLabels = {
  kernel: "Kernel Commands",
  action: "Project Actions",
};
// Public command segments cannot start with `_`, so this key cannot collide.
const SYSTEM_KEY = "__system__";

export function createExplorerView({
  breadcrumb,
  columns,
  detailPanel,
  onSelectCommand,
  onSelectSystem,
}) {
  let catalog = null;
  let selectedPath = [];
  let systemSelected = true;
  let selectedSystemPage = "overview";
  let setupRequired = false;

  function createCommandRow(command, depth) {
    const item = document.createElement("li");
    const button = document.createElement("button");
    const icon = document.createElement("span");
    const copy = document.createElement("span");
    const name = document.createElement("span");
    const summary = document.createElement("span");
    const chevron = document.createElement("span");
    const group = isGroup(catalog, command);
    const expandable = hasChildren(catalog, command);
    const selected = !systemSelected
      && selectedPath[depth] === command.address;

    button.type = "button";
    button.className = "command-row";
    button.dataset.address = command.address;
    button.dataset.depth = String(depth);
    button.dataset.kind = group ? "group" : "command";
    button.dataset.navigationKey = command.address;
    button.disabled = setupRequired;
    if (selected) {
      button.setAttribute("aria-current", "page");
    }
    if (expandable) {
      button.setAttribute("aria-expanded", String(selected));
      if (selected) {
        button.setAttribute("aria-controls", `finder-column-${depth + 1}`);
      }
    }
    button.title = setupRequired ? "完成首次设置后可用" : command.address;

    icon.className = "row-icon";
    icon.textContent = group ? "⌑" : ">_";
    icon.setAttribute("aria-hidden", "true");

    copy.className = "row-copy";
    name.className = "row-name";
    name.textContent = depth === 0 ? command.address : leafName(command.address);
    summary.className = "row-summary";
    summary.textContent = command.summary || (
      command.issue
        ? "存在协议问题"
        : expandable && command.runnable
          ? "可运行命令组"
          : expandable
            ? "命令组"
            : command.runnable
              ? "可运行命令"
              : "不可运行"
    );
    copy.append(name, summary);

    chevron.className = "row-chevron";
    chevron.textContent = expandable ? "›" : "";
    chevron.setAttribute("aria-hidden", "true");

    button.append(icon, copy, chevron);
    button.addEventListener("click", (event) => {
      selectCommand(command.address, depth, {
        focusDetail: event.detail === 0,
      });
    });
    item.append(button);
    return item;
  }

  function createSystemRow() {
    const item = document.createElement("li");
    const button = document.createElement("button");
    const icon = document.createElement("span");
    const copy = document.createElement("span");
    const name = document.createElement("span");
    const summary = document.createElement("span");
    const chevron = document.createElement("span");

    button.type = "button";
    button.className = "command-row";
    button.dataset.depth = "0";
    button.dataset.kind = "system";
    button.dataset.navigationKey = SYSTEM_KEY;
    button.title = "系统信息";
    button.setAttribute("aria-expanded", String(systemSelected));
    if (systemSelected) {
      button.setAttribute("aria-current", "page");
    }

    icon.className = "row-icon";
    icon.textContent = "▦";
    icon.setAttribute("aria-hidden", "true");

    copy.className = "row-copy";
    name.className = "row-name";
    name.textContent = "Swaw Kit";
    summary.className = "row-summary";
    summary.textContent = setupRequired ? "需要完成首次设置" : "Host 已连接";
    copy.append(name, summary);

    chevron.className = "row-chevron";
    chevron.textContent = "›";
    chevron.setAttribute("aria-hidden", "true");

    button.append(icon, copy, chevron);
    button.addEventListener("click", (event) => {
      selectSystem({ focusDetail: event.detail === 0 });
    });
    item.append(button);
    return item;
  }

  function appendSystemSection(column) {
    const section = document.createElement("section");
    const heading = document.createElement("h2");
    const list = document.createElement("ul");
    section.className = "column-section";
    heading.className = "column-label";
    heading.textContent = "System";
    list.className = "column-list";
    list.append(createSystemRow());
    section.append(heading, list);
    column.append(section);
  }

  function appendSection(column, label, commands, depth) {
    if (commands.length === 0) {
      return;
    }

    const section = document.createElement("section");
    const list = document.createElement("ul");
    section.className = "column-section";
    list.className = "column-list";

    for (const command of sortCommands(catalog, commands)) {
      list.append(createCommandRow(command, depth));
    }
    if (label) {
      const heading = document.createElement("h2");
      heading.className = "column-label";
      heading.textContent = label;
      section.append(heading);
    }
    section.append(list);
    column.append(section);
  }

  function createRootColumn() {
    const column = document.createElement("div");
    const kernel = catalog.roots
      .filter((command) => command.source === "kernel");
    const actions = catalog.roots
      .filter((command) => command.source === "action");
    column.className = "finder-column";
    column.id = "finder-column-0";
    column.dataset.depth = "0";
    appendSystemSection(column);
    appendSection(column, sourceLabels.kernel, kernel, 0);
    appendSection(column, sourceLabels.action, actions, 0);

    if (kernel.length === 0 && actions.length === 0) {
      const empty = document.createElement("p");
      empty.className = "empty-column";
      empty.textContent = "Catalog 中没有可显示的命令。";
      column.append(empty);
    }
    return column;
  }

  function createChildColumn(parentAddress, depth) {
    const column = document.createElement("div");
    const parent = catalog.commandByAddress.get(parentAddress);
    column.className = "finder-column";
    column.id = `finder-column-${depth}`;
    column.dataset.depth = String(depth);
    column.setAttribute("role", "group");
    column.setAttribute(
      "aria-label",
      `${parent.address} 子命令`,
    );
    appendSection(column, null, childrenOf(catalog, parentAddress), depth);
    return column;
  }

  function renderColumns({
    focusKey = null,
    focusDetail = false,
    scrollTarget = null,
  } = {}) {
    columns.replaceChildren(createRootColumn());
    if (systemSelected) {
      columns.append(createSystemNavigationColumn({
        selectedPage: selectedSystemPage,
        onSelect: selectSystemPage,
      }));
    }
    for (const [depth, address] of selectedPath.entries()) {
      if (hasChildren(catalog, catalog.commandByAddress.get(address))) {
        columns.append(createChildColumn(address, depth + 1));
      }
    }

    requestAnimationFrame(() => {
      const focusTarget = focusKey
        ? [...columns.querySelectorAll(".command-row")]
          .find((row) => row.dataset.navigationKey === focusKey)
        : null;
      if (scrollTarget === "detail") {
        if (focusDetail) {
          detailPanel.focus({ preventScroll: true });
        } else {
          focusTarget?.focus({ preventScroll: true });
        }
        detailPanel.scrollIntoView({ block: "nearest", inline: "nearest" });
      } else if (scrollTarget === "navigation") {
        focusTarget?.focus({ preventScroll: true });
        columns.lastElementChild?.scrollIntoView({ block: "nearest", inline: "nearest" });
      } else {
        focusTarget?.focus({ preventScroll: true });
        if (scrollTarget === "focus") {
          focusTarget?.scrollIntoView({ block: "nearest", inline: "nearest" });
        }
      }
    });
  }

  function renderBreadcrumb() {
    const fragment = document.createDocumentFragment();
    const home = document.createElement("span");
    home.className = "breadcrumb-home";
    home.textContent = "控制台";
    fragment.append(home);

    const items = systemSelected
      ? ["系统", systemPageLabel(selectedSystemPage)]
      : selectedPath.map((address, depth) => (
        depth === 0 ? address : leafName(address)
      ));
    for (const label of items) {
      const separator = document.createElement("span");
      const item = document.createElement("span");
      separator.className = "breadcrumb-separator";
      separator.textContent = "›";
      separator.setAttribute("aria-hidden", "true");
      item.className = "breadcrumb-item";
      item.textContent = label;
      fragment.append(separator, item);
    }
    breadcrumb.replaceChildren(fragment);
    breadcrumb.scrollLeft = breadcrumb.scrollWidth;
  }

  function selectCommand(address, depth, options = {}) {
    if (setupRequired) {
      return;
    }
    const command = catalog.commandByAddress.get(address);
    if (!command) {
      return;
    }

    systemSelected = false;
    selectedPath = [...selectedPath.slice(0, depth), address];
    onSelectCommand(command);
    renderBreadcrumb();
    renderColumns({
      focusKey: Object.hasOwn(options, "focusKey")
        ? options.focusKey
        : address,
      focusDetail: options.focusDetail === true,
      scrollTarget: options.scrollTarget
        ?? (hasChildren(catalog, command) ? "navigation" : "detail"),
    });
  }

  function selectSystem(options = {}) {
    systemSelected = true;
    selectedPath = [];
    selectedSystemPage = defaultSystemPage(setupRequired);
    onSelectSystem(selectedSystemPage);
    renderBreadcrumb();
    renderColumns({
      focusKey: SYSTEM_KEY,
      focusDetail: options.focusDetail === true,
      scrollTarget: "navigation",
    });
  }

  function selectSystemPage(page, options = {}) {
    if (!isSystemPage(page)) {
      return;
    }
    systemSelected = true;
    selectedPath = [];
    selectedSystemPage = page;
    onSelectSystem(page);
    renderBreadcrumb();
    renderColumns({
      focusKey: `__system__.${page}`,
      focusDetail: options.focusDetail === true,
      scrollTarget: "detail",
    });
  }

  function handleKeyboard(event) {
    const button = event.target.closest(".command-row");
    if (!button) {
      return;
    }

    const rows = [...button.closest(".finder-column")?.querySelectorAll(".command-row") ?? []];
    const index = rows.indexOf(button);
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      const offset = event.key === "ArrowDown" ? 1 : -1;
      rows[(index + offset + rows.length) % rows.length]?.focus();
      return;
    }

    const depth = Number(button.dataset.depth);
    if (
      button.dataset.kind === "system"
      && (event.key === "Enter" || event.key === " ")
    ) {
      event.preventDefault();
      selectSystem({ focusDetail: true });
      return;
    }
    if (
      button.dataset.kind === "system-page"
      && (event.key === "Enter" || event.key === " ")
    ) {
      event.preventDefault();
      selectSystemPage(button.dataset.page, { focusDetail: true });
      return;
    }

    if (event.key === "ArrowRight") {
      const address = button.dataset.address;
      const children = address ? childrenOf(catalog, address) : [];
      if (children.length > 0) {
        event.preventDefault();
        selectCommand(address, depth, {
          focusKey: null,
          scrollTarget: "navigation",
        });
        requestAnimationFrame(() => {
          const nextColumn = columns.querySelector(`[data-depth="${depth + 1}"]`);
          nextColumn?.querySelector(".command-row")?.focus();
        });
      }
    } else if (event.key === "ArrowLeft" && depth > 0) {
      event.preventDefault();
      const parentAddress = selectedPath[depth - 1];
      selectCommand(parentAddress, depth - 1, { scrollTarget: "focus" });
    } else if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      selectCommand(button.dataset.address, depth, { focusDetail: true });
    }
  }

  function setCatalog(nextCatalog) {
    catalog = nextCatalog;
    selectedPath = [];
    systemSelected = true;
    selectedSystemPage = defaultSystemPage(setupRequired);
    onSelectSystem(selectedSystemPage);
    renderBreadcrumb();
    renderColumns();
  }

  function setSetupRequired(required) {
    setupRequired = required;
    systemSelected = true;
    selectedPath = [];
    selectedSystemPage = defaultSystemPage(required);
    if (catalog) {
      onSelectSystem(selectedSystemPage);
      renderBreadcrumb();
      renderColumns();
    }
  }

  return {
    handleKeyboard,
    selectCommand,
    selectSystem,
    selectSystemPage,
    setCatalog,
    setSetupRequired,
  };
}
