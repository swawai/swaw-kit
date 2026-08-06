// Trusted UI sections owned by the built-in Entry Profile renderer.
export const entryPages = Object.freeze([
  Object.freeze({
    id: "project",
    title: "项目绑定",
    summary: "当前入口所控制的目标项目。",
  }),
  Object.freeze({
    id: "preferences",
    title: "交互偏好",
    summary: "命令模块可共享的 Shell、IDE 与帮助语言声明。",
  }),
  Object.freeze({
    id: "development",
    title: "开发环境",
    summary: "由项目管理或复用的开发工具声明。",
  }),
  Object.freeze({
    id: "git",
    title: "Git 与仓库",
    summary: "按 Entry 隔离的可选身份、访问方式与远端信息。",
  }),
]);

export function entryPage(page) {
  return entryPages.find(({ id }) => id === page) ?? entryPages[0];
}

export function isEntryPage(page) {
  return entryPages.some(({ id }) => id === page);
}

export function defaultEntryPage() {
  return entryPages[0].id;
}

export function entryPageLabel(page) {
  return entryPage(page).title;
}

export function createEntryNavigationColumn({
  selectedPage,
  onSelect,
  commandRows = [],
}) {
  const column = document.createElement("div");
  const section = document.createElement("section");
  const heading = document.createElement("h2");
  const list = document.createElement("ul");
  column.className = "finder-column";
  column.id = "finder-column-entry";
  column.dataset.depth = "1";
  column.setAttribute("role", "group");
  column.setAttribute("aria-label", "Entry Profile");
  section.className = "column-section";
  heading.className = "column-label";
  heading.textContent = "Entry Profile";
  list.className = "column-list";

  for (const { id: page, title, summary: summaryText } of entryPages) {
    const item = document.createElement("li");
    const button = document.createElement("button");
    const icon = document.createElement("span");
    const copy = document.createElement("span");
    const name = document.createElement("span");
    const summary = document.createElement("span");
    const chevron = document.createElement("span");
    button.type = "button";
    button.className = "command-row";
    button.dataset.depth = "1";
    button.dataset.kind = "entry-page";
    button.dataset.page = page;
    button.dataset.navigationKey = `__entry__.${page}`;
    if (selectedPage === page) {
      button.setAttribute("aria-current", "page");
    }
    icon.className = "row-icon";
    icon.textContent = "·";
    icon.setAttribute("aria-hidden", "true");
    copy.className = "row-copy";
    name.className = "row-name";
    name.textContent = title;
    summary.className = "row-summary";
    summary.textContent = summaryText;
    copy.append(name, summary);
    chevron.className = "row-chevron";
    chevron.setAttribute("aria-hidden", "true");
    button.append(icon, copy, chevron);
    button.addEventListener("click", (event) => {
      onSelect(page, { focusDetail: event.detail === 0 });
    });
    item.append(button);
    list.append(item);
  }
  section.append(heading, list);
  column.append(section);

  if (commandRows.length > 0) {
    const commandSection = document.createElement("section");
    const commandHeading = document.createElement("h2");
    const commandList = document.createElement("ul");
    commandSection.className = "column-section";
    commandHeading.className = "column-label";
    commandHeading.textContent = "CLI";
    commandList.className = "column-list";
    commandList.append(...commandRows);
    commandSection.append(commandHeading, commandList);
    column.append(commandSection);
  }
  return column;
}
