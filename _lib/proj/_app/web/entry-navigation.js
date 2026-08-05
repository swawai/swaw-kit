// Trusted UI sections owned by the built-in Entry Profile renderer.
export const entryPages = [
  ["project", "项目绑定", "目标项目与解析结果"],
  ["preferences", "交互偏好", "Shell、IDE 与帮助语言"],
  ["development", "开发环境", "工具模式与版本声明"],
  ["git", "Git 与仓库", "身份、访问方式与远端"],
];

export function isEntryPage(page) {
  return entryPages.some(([candidate]) => candidate === page);
}

export function defaultEntryPage() {
  return "project";
}

export function entryPageLabel(page) {
  return entryPages.find(([candidate]) => candidate === page)?.[1] ?? "项目绑定";
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

  for (const [page, label, summaryText] of entryPages) {
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
    name.textContent = label;
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
