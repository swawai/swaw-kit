import {
  childrenOf,
  hasChildren,
  isGroup,
  leafName,
  sortCommands,
} from "./catalog-model.js";
import {
  createEntryNavigationColumn,
  defaultEntryPage,
  entryPageLabel,
  isEntryPage,
} from "./entry-navigation.js";

const sourceLabels = {
  control: "Control Plane",
  kernel: "Kernel Commands",
  action: "Project Actions",
};
const ENTRY_PROFILE_HANDLER = "entry.profile";
const ENTRY_PAGE_KEY_PREFIX = "__entry__.";

export function commandDisabledDuringSetup(setupRequired, command) {
  return setupRequired && command.source !== "control";
}

export function findEntryProfileCommand(catalog) {
  return catalog?.roots.find((command) => (
    command.source === "control"
    && command.handler === ENTRY_PROFILE_HANDLER
  )) ?? null;
}

export function controlledColumnId(command, depth) {
  return command.handler === ENTRY_PROFILE_HANDLER
    ? "finder-column-entry"
    : `finder-column-${depth + 1}`;
}

export function createExplorerView({
  breadcrumb,
  columns,
  detailPanel,
  onSelectCommand,
  onSelectEntryPage,
}) {
  let catalog = null;
  let selectedPath = [];
  let entryProfileSelected = false;
  let selectedEntryPage = defaultEntryPage();
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
    const selected = selectedPath[depth] === command.address;
    const disabled = commandDisabledDuringSetup(setupRequired, command);

    button.type = "button";
    button.className = "command-row";
    button.dataset.address = command.address;
    button.dataset.depth = String(depth);
    button.dataset.kind = group ? "group" : "command";
    button.dataset.navigationKey = command.address;
    button.disabled = disabled;
    if (selected) {
      button.setAttribute("aria-current", "page");
    }
    if (expandable) {
      button.setAttribute("aria-expanded", String(selected));
      if (selected) {
        button.setAttribute("aria-controls", controlledColumnId(command, depth));
      }
    }
    button.title = disabled ? "完成首次设置后可用" : command.address;

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
    const control = catalog.roots
      .filter((command) => command.source === "control");
    const kernel = catalog.roots
      .filter((command) => command.source === "kernel");
    const actions = catalog.roots
      .filter((command) => command.source === "action");
    column.className = "finder-column";
    column.id = "finder-column-0";
    column.dataset.depth = "0";
    appendSection(column, sourceLabels.control, control, 0);
    appendSection(column, sourceLabels.kernel, kernel, 0);
    appendSection(column, sourceLabels.action, actions, 0);

    if (control.length === 0 && kernel.length === 0 && actions.length === 0) {
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
    const entryCommand = findEntryProfileCommand(catalog);
    const entryPathActive = entryCommand
      && selectedPath[0] === entryCommand.address;
    if (entryPathActive) {
      const commandRows = sortCommands(
        catalog,
        childrenOf(catalog, entryCommand.address),
      ).map((command) => createCommandRow(command, 1));
      columns.append(createEntryNavigationColumn({
        selectedPage: entryProfileSelected ? selectedEntryPage : null,
        onSelect: selectEntryPage,
        commandRows,
      }));
    }
    for (const [depth, address] of selectedPath.entries()) {
      if (entryPathActive && depth === 0) {
        continue;
      }
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

    const entryCommand = findEntryProfileCommand(catalog);
    const items = entryProfileSelected && entryCommand
      ? [entryCommand.address, entryPageLabel(selectedEntryPage)]
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
    const command = catalog.commandByAddress.get(address);
    if (!command || commandDisabledDuringSetup(setupRequired, command)) {
      return;
    }

    selectedPath = [...selectedPath.slice(0, depth), address];
    if (command.handler === ENTRY_PROFILE_HANDLER) {
      entryProfileSelected = true;
      selectedEntryPage = defaultEntryPage();
      onSelectEntryPage(selectedEntryPage);
    } else {
      entryProfileSelected = false;
      onSelectCommand(command);
    }
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

  function selectEntryProfile(options = {}) {
    const command = findEntryProfileCommand(catalog);
    if (!command) {
      return;
    }
    entryProfileSelected = true;
    selectedPath = [command.address];
    selectedEntryPage = defaultEntryPage();
    onSelectEntryPage(selectedEntryPage);
    renderBreadcrumb();
    renderColumns({
      focusKey: command.address,
      focusDetail: options.focusDetail === true,
      scrollTarget: "navigation",
    });
  }

  function selectEntryPage(page, options = {}) {
    const command = findEntryProfileCommand(catalog);
    if (!command || !isEntryPage(page)) {
      return;
    }
    entryProfileSelected = true;
    selectedPath = [command.address];
    selectedEntryPage = page;
    onSelectEntryPage(page);
    renderBreadcrumb();
    renderColumns({
      focusKey: `${ENTRY_PAGE_KEY_PREFIX}${page}`,
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
      button.dataset.kind === "entry-page"
      && (event.key === "Enter" || event.key === " ")
    ) {
      event.preventDefault();
      selectEntryPage(button.dataset.page, { focusDetail: true });
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
    entryProfileSelected = false;
    const command = findEntryProfileCommand(catalog);
    if (command) {
      entryProfileSelected = true;
      selectedPath = [command.address];
      selectedEntryPage = defaultEntryPage();
      onSelectEntryPage(selectedEntryPage);
    }
    renderBreadcrumb();
    renderColumns();
  }

  function setSetupRequired(required) {
    setupRequired = required;
    if (catalog) {
      selectEntryProfile();
    }
  }

  return {
    handleKeyboard,
    selectCommand,
    selectEntryProfile,
    selectEntryPage,
    setCatalog,
    setSetupRequired,
  };
}
