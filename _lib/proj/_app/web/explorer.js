import {
  childrenOf,
  isGroup,
  leafName,
  sortCommands,
} from "./catalog-model.js";
import {
  availableCommand,
  childrenColumnWidth,
  choiceColumnModels,
  commandHasChoices,
  commandMenuExpanded,
  selectedCommandFacet,
} from "./explorer-model.js";
import {
  commandMenuId,
} from "./command-menu-position.js";
import {
  closeCommandMenu,
  commandMenuFor,
  commandMenuToggleFor,
  setCommandMenuToggleState,
  showCommandMenu,
} from "./command-menu.js";
import { t } from "./i18n.js";
import { appendSubjectSection } from "./subject-explorer.js";

export {
  availableCommand,
  childrenColumnWidth,
  choiceColumnModels,
  commandHasChoices,
  commandMenuExpanded,
} from "./explorer-model.js";

function spaceLabel(space) {
  return space === "system"
    ? t("系统命令", "System Commands")
    : t("模块命名空间", "Module Namespaces");
}

export function captureColumnScrollOffsets(columns) {
  return new Map(
    [...columns.querySelectorAll(".finder-column")]
      .map((column) => [column.dataset.scrollKey, column.scrollTop]),
  );
}

export function restoreColumnScrollOffsets(columns, offsets) {
  for (const column of columns.querySelectorAll(".finder-column")) {
    const offset = offsets.get(column.dataset.scrollKey);
    if (offset !== undefined) {
      column.scrollTop = offset;
    }
  }
}

export function createExplorerView({
  columns,
  detailPanel,
  getCommandFacets = () => [],
  getSubjectFacets = () => [],
  onSelectCommand,
  onSelectSubject = () => {},
}) {
  let catalog = null;
  let selectedPath = [];
  let selectedSubjectRef = null;
  let selectedSubjectCollection = null;
  let expandedCommandMenuAddress = null;
  const commandStates = new Map();
  const subjectCollections = new Map();
  const subjectCollectionErrors = new Map();

  function collectionKey(owner, facet) {
    return `${owner}#${facet}`;
  }

  function facetsFor(command) {
    return getCommandFacets(command);
  }

  function isCollectionFacet(command, facet) {
    return facetsFor(command).some((candidate) => (
      candidate.name === facet && candidate.kind === "collection"
    ));
  }

  function showExpandedCommandMenu({ focusFirst = false } = {}) {
    if (!expandedCommandMenuAddress) {
      return;
    }
    if (!showCommandMenu(
      columns,
      expandedCommandMenuAddress,
      { focusFirst },
    )) {
      expandedCommandMenuAddress = null;
    }
  }

  function dismissExpandedCommandMenu(restoreFocus = false) {
    const address = expandedCommandMenuAddress;
    if (!address) {
      return;
    }
    expandedCommandMenuAddress = null;
    closeCommandMenu(columns, address, { restoreFocus });
  }

  function createCommandRow(command, depth) {
    const item = document.createElement("li");
    const button = document.createElement("button");
    const icon = document.createElement("span");
    const copy = document.createElement("span");
    const name = document.createElement("span");
    const summary = document.createElement("span");
    const group = isGroup(catalog, command);
    const facets = facetsFor(command);
    const expandable = commandHasChoices(catalog, command, facets);
    const selected = selectedPath[depth] === command.address;
    const terminal = selected && depth === selectedPath.length - 1;
    const menuExpanded = commandMenuExpanded(
      expandedCommandMenuAddress,
      command.address,
    );
    const state = commandStates.get(command.address);

    button.type = "button";
    button.className = "finder-choice command-row";
    button.dataset.address = command.address;
    button.dataset.depth = String(depth);
    button.dataset.kind = group ? "group" : "command";
    button.dataset.navigationKey = command.address;
    button.dataset.selected = String(selected);
    button.dataset.expandable = String(expandable);
    if (state?.tone) {
      button.dataset.stateTone = state.tone;
    }
    if (terminal) {
      button.setAttribute("aria-current", "page");
    }
    if (selected && group) {
      button.setAttribute("aria-controls", `finder-column-${depth + 1}`);
    }
    button.title = command.address;

    icon.className = "row-icon";
    icon.textContent = state?.icon ?? (group ? "⌑" : ">_");
    icon.setAttribute("aria-hidden", "true");
    copy.className = "row-copy";
    name.className = "row-name";
    name.textContent = depth === 0 ? command.address : leafName(command.address);
    summary.className = "row-summary";
    summary.textContent = (state?.summary ?? command.summary) || (
      command.issue
        ? t("存在协议问题", "Protocol issue")
        : expandable && command.runnable
          ? t("可运行命令组", "Runnable command group")
          : expandable
            ? t("命令组", "Command group")
            : command.runnable
              ? t("可运行命令", "Runnable command")
              : t("不可运行", "Not runnable")
    );
    copy.append(name, summary);
    button.append(icon, copy);
    button.addEventListener("click", (event) => {
      selectCommand(command.address, depth, {
        focusDetail: event.detail === 0,
        history: "push",
        menu: expandable ? "open" : "close",
      });
    });
    item.className = "command-item";
    item.append(button);
    if (expandable) {
      const toggle = document.createElement("button");
      const toggleIcon = document.createElement("span");
      toggle.type = "button";
      toggle.className = "command-menu-toggle";
      toggle.dataset.address = command.address;
      toggle.dataset.selected = String(selected);
      toggle.setAttribute("aria-haspopup", "menu");
      toggle.setAttribute("popovertarget", commandMenuId(command.address, depth));
      toggle.setAttribute("popovertargetaction", "toggle");
      setCommandMenuToggleState(toggle, command.address, menuExpanded);
      toggleIcon.className = "command-menu-toggle-icon";
      toggleIcon.textContent = "›";
      toggleIcon.setAttribute("aria-hidden", "true");
      toggle.append(toggleIcon);
      item.append(toggle, createCommandFacetMenu(command, depth, facets));
    }
    return item;
  }

  function createCommandFacetRow(command, depth, facet) {
    const item = document.createElement("li");
    const button = document.createElement("button");
    const icon = document.createElement("span");
    const name = document.createElement("span");

    button.type = "button";
    button.className = "finder-choice command-facet-row";
    button.dataset.facet = facet.name;
    button.dataset.parentAddress = command.address;
    button.dataset.parentDepth = String(depth);
    button.dataset.navigationKey = `${command.address}#${facet.name}`;
    button.setAttribute("aria-checked", String(facet.selected));
    button.setAttribute("role", "menuitemradio");
    button.title = facet.summary;

    icon.className = "row-icon facet-icon";
    icon.textContent = facet.icon;
    icon.setAttribute("aria-hidden", "true");
    name.className = "row-name";
    name.textContent = facet.label;

    button.append(icon, name);
    button.addEventListener("click", () => {
      selectCommand(command.address, depth, {
        focusDetail: facet.kind !== "collection",
        history: "push",
        facet: facet.name,
        menu: "close",
      });
    });
    item.append(button);
    return item;
  }

  function createCommandFacetMenu(command, depth, facets) {
    const group = document.createElement("div");
    const list = document.createElement("ul");
    group.className = "command-facet-popover";
    group.dataset.address = command.address;
    group.id = commandMenuId(command.address, depth);
    group.setAttribute("popover", "auto");
    group.setAttribute("role", "menu");
    group.setAttribute(
      "aria-label",
      t(`${command.address} 能力面`, `${command.address} facets`),
    );
    list.className = "command-facet-menu";
    for (const facet of facets) {
      list.append(createCommandFacetRow(command, depth, facet));
    }
    group.append(list);
    group.addEventListener("toggle", (event) => {
      if (event.newState === "open") {
        expandedCommandMenuAddress = command.address;
        showExpandedCommandMenu();
      } else if (expandedCommandMenuAddress === command.address) {
        expandedCommandMenuAddress = null;
        const toggle = commandMenuToggleFor(columns, command.address);
        if (toggle) {
          setCommandMenuToggleState(toggle, command.address, false);
        }
      }
    });
    return group;
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
    column.className = "finder-column";
    column.id = "finder-column-0";
    column.dataset.depth = "0";
    column.dataset.scrollKey = "root";
    column.dataset.width = "normal";
    for (const space of ["system", "module"]) {
      appendSection(
        column,
        spaceLabel(space),
        catalog.roots.filter((command) => command.space === space),
        0,
      );
    }
    if (catalog.roots.length === 0) {
      const empty = document.createElement("p");
      empty.className = "empty-column";
      empty.textContent = t(
        "Catalog 中没有可显示的命令。",
        "The Catalog has no commands to display.",
      );
      column.append(empty);
    }
    return column;
  }

  function createChoiceColumn(parentAddress, depth, mode) {
    const column = document.createElement("div");
    const parent = catalog.commandByAddress.get(parentAddress);
    const facet = facetsFor(parent).find(({ name }) => name === mode);
    column.className = "finder-column";
    column.id = `finder-column-${depth}`;
    column.dataset.depth = String(depth);
    column.dataset.scrollKey = `${mode}:${parentAddress}`;
    column.dataset.width = childrenColumnWidth(parent);
    column.setAttribute("role", "group");
    column.setAttribute(
      "aria-label",
      facet?.label ?? t(`${parent.address} 集合`, `${parent.address} collection`),
    );
    if (facet?.resolver?.type === "catalog" && facet.resolver.relation === "children") {
      appendSection(
        column,
        facet.label,
        childrenOf(catalog, parentAddress),
        depth,
      );
    } else {
      const key = collectionKey(parentAddress, mode);
      appendSubjectSection({
        collection: subjectCollections.get(key),
        column,
        error: subjectCollectionErrors.get(key),
        getSubjectFacets,
        label: facet?.label,
        onSelect: selectSubjectRecord,
        selectedSubjectRef,
      });
    }
    return column;
  }

  function renderColumns({
    focusKey = null,
    focusDetail = false,
    focusMenu = false,
  } = {}) {
    const scrollOffsets = captureColumnScrollOffsets(columns);
    columns.replaceChildren(createRootColumn());
    const models = choiceColumnModels(
      catalog,
      selectedPath,
      facetsFor,
      selectedSubjectCollection,
    );
    for (const { command, depth, mode } of models) {
      columns.append(createChoiceColumn(command.address, depth, mode));
    }
    restoreColumnScrollOffsets(columns, scrollOffsets);

    requestAnimationFrame(() => {
      showExpandedCommandMenu({ focusFirst: focusMenu });
      const focusTarget = focusKey
        ? [...columns.querySelectorAll(".finder-choice")]
          .find((row) => row.dataset.navigationKey === focusKey)
        : null;
      if (focusMenu) {
        // showExpandedCommandMenu moved focus into the floating menu.
      } else if (focusDetail) {
        detailPanel.focus({ preventScroll: true });
        detailPanel.scrollIntoView({ block: "nearest", inline: "nearest" });
      } else {
        focusTarget?.focus({ preventScroll: true });
        columns.lastElementChild?.scrollIntoView({ block: "nearest", inline: "nearest" });
      }
      // Browser focus and scrollIntoView may also move a nested scroll container.
      // Reapply the semantic column offsets after those side effects settle.
      restoreColumnScrollOffsets(columns, scrollOffsets);
    });
  }

  function selectCommand(address, depth, options = {}) {
    const command = availableCommand(catalog, address);
    if (!command) {
      return false;
    }
    selectedSubjectRef = null;
    selectedSubjectCollection = null;
    selectedPath = [...selectedPath.slice(0, depth), address];
    if (options.menu === "open") {
      expandedCommandMenuAddress = address;
    } else if (options.menu === "close") {
      expandedCommandMenuAddress = null;
    }
    onSelectCommand(command, options);
    const facet = selectedCommandFacet(facetsFor(command));
    renderColumns({
      focusKey: address,
      focusDetail: options.focusDetail === true && !isCollectionFacet(command, facet),
      focusMenu: options.focusMenu === true,
    });
    return true;
  }

  function addressPath(address) {
    const path = [];
    let current = catalog.commandByAddress.get(address);
    while (current) {
      path.unshift(current.address);
      current = current.parent
        ? catalog.commandByAddress.get(current.parent)
        : null;
    }
    return path;
  }

  function selectAddress(address, options = {}) {
    const command = availableCommand(catalog, address);
    if (!command) {
      return false;
    }
    selectedSubjectRef = null;
    selectedSubjectCollection = null;
    selectedPath = addressPath(address);
    expandedCommandMenuAddress = facetsFor(command).length > 0
      ? address
      : null;
    onSelectCommand(command, options);
    const facet = selectedCommandFacet(facetsFor(command));
    renderColumns({
      focusKey: address,
      focusDetail: options.focusDetail === true && !isCollectionFacet(command, facet),
    });
    return true;
  }

  function selectSubjectRecord(subject, options = {}) {
    const key = collectionKey(subject.owner, subject.collectionFacet);
    const current = subjectCollections.get(key)?.subjectByRef.get(subject.canonicalRef);
    if (!current) {
      return false;
    }
    const owner = availableCommand(catalog, current.owner);
    if (!owner) {
      return false;
    }
    selectedPath = addressPath(owner.address);
    selectedSubjectRef = current.canonicalRef;
    selectedSubjectCollection = { facet: current.collectionFacet, owner: current.owner };
    expandedCommandMenuAddress = null;
    onSelectSubject(current, options);
    renderColumns({
      focusKey: current.canonicalRef,
      focusDetail: options.focusDetail === true,
    });
    return true;
  }

  function selectSubject(owner, facet, reference, options = {}) {
    const subject = subjectCollections.get(collectionKey(owner, facet))?.subjectByRef.get(reference);
    return subject ? selectSubjectRecord(subject, options) : false;
  }

  function defaultCommand() {
    return sortCommands(catalog, catalog.roots)[0] ?? null;
  }

  function handleKeyboard(event) {
    const button = event.target.closest(".finder-choice");
    if (!button) {
      return;
    }
    const rows = [
      ...button.closest(".finder-column")?.querySelectorAll(".finder-choice") ?? [],
    ].filter((row) => row.getClientRects().length > 0);
    const index = rows.indexOf(button);
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      const offset = event.key === "ArrowDown" ? 1 : -1;
      rows[(index + offset + rows.length) % rows.length]?.focus();
      return;
    }

    if (!button.classList.contains("command-row")) {
      if (event.key === "ArrowLeft") {
        event.preventDefault();
        const parentAddress = button.dataset.parentAddress;
        columns.querySelector(
          `.command-row[data-address="${CSS.escape(parentAddress)}"]`,
        )?.focus();
      }
      return;
    }

    const depth = Number(button.dataset.depth);
    if (event.key === "ArrowRight") {
      const command = catalog.commandByAddress.get(button.dataset.address);
      const facets = command ? facetsFor(command) : [];
      if (
        command
        && commandHasChoices(catalog, command, facets)
      ) {
        event.preventDefault();
        selectCommand(button.dataset.address, depth, {
          focusMenu: true,
          history: "push",
          menu: "open",
        });
      }
    } else if (event.key === "ArrowLeft" && depth > 0) {
      event.preventDefault();
      selectAddress(selectedPath[depth - 1], { history: "push" });
    } else if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      selectCommand(button.dataset.address, depth, {
        focusDetail: true,
        history: "push",
        menu: "open",
      });
    }
  }

  function setCatalog(nextCatalog, options = {}) {
    const previous = selectedPath.at(-1);
    catalog = nextCatalog;
    const preferred = options.address ?? previous;
    const preferredCommand = preferred
      ? availableCommand(catalog, preferred)
      : null;
    if (preferredCommand) {
      selectAddress(preferred, {
        history: options.history ?? "none",
        facet: options.facet,
      });
      return;
    }
    const command = defaultCommand();
    if (command) {
      selectAddress(command.address, { history: options.history ?? "none" });
    } else {
      selectedPath = [];
      renderColumns();
    }
  }

  function setSubjectCollection(collection) {
    const selected = selectedSubjectRef;
    if (collection) {
      const key = collectionKey(collection.owner, collection.facet);
      subjectCollections.set(key, collection);
      subjectCollectionErrors.delete(key);
    }
    if (!catalog) {
      return;
    }
    if (selected) {
      const current = [...subjectCollections.values()]
        .flatMap(({ subjects }) => subjects)
        .find(({ canonicalRef }) => canonicalRef === selected);
      if (current) {
        selectedSubjectRef = current.canonicalRef;
      } else {
        const owner = selectedSubjectCollection?.owner;
        const facet = selectedSubjectCollection?.facet;
        selectedSubjectRef = null;
        selectedSubjectCollection = null;
        const command = owner
          ? availableCommand(catalog, owner)
          : null;
        if (command) {
          selectedPath = addressPath(owner);
          onSelectCommand(command, {
            history: "replace",
            facet,
          });
        }
      }
    }
    renderColumns();
  }

  function setSubjectCollectionLoading(owner, facet) {
    const key = collectionKey(owner, facet);
    subjectCollections.delete(key);
    subjectCollectionErrors.delete(key);
    if (catalog) {
      renderColumns();
    }
  }

  function setSubjectCollectionError(owner, facet, message) {
    const key = collectionKey(owner, facet);
    subjectCollections.delete(key);
    subjectCollectionErrors.set(key, message);
    if (catalog) {
      renderColumns();
    }
  }

  function setCommandState(address, state) {
    if (state) {
      commandStates.set(address, state);
    } else {
      commandStates.delete(address);
    }
    if (catalog) {
      renderColumns();
    }
  }

  columns.addEventListener("scroll", () => {
    showExpandedCommandMenu();
  }, true);
  document.addEventListener("pointerdown", (event) => {
    const address = expandedCommandMenuAddress;
    const menu = address ? commandMenuFor(columns, address) : null;
    const toggle = address ? commandMenuToggleFor(columns, address) : null;
    if (menu && !menu.contains(event.target) && !toggle?.contains(event.target)) {
      dismissExpandedCommandMenu();
    }
  }, true);
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && expandedCommandMenuAddress) {
      event.preventDefault();
      dismissExpandedCommandMenu(true);
    }
  }, true);
  window.addEventListener("resize", () => {
    showExpandedCommandMenu();
  });

  return {
    handleKeyboard,
    selectAddress,
    selectCommand,
    selectSubject,
    setCatalog,
    setCommandState,
    setSubjectCollection,
    setSubjectCollectionError,
    setSubjectCollectionLoading,
  };
}
