export const systemPages = [
  ["overview", "概览", "Host 与 Catalog 状态"],
  ["project", "项目绑定", "目标项目与解析结果"],
  ["preferences", "交互偏好", "Shell、IDE 与帮助语言"],
  ["development", "开发环境", "工具模式与版本声明"],
  ["git", "Git 与仓库", "身份、访问方式与远端"],
];

export function isSystemPage(page) {
  return systemPages.some(([candidate]) => candidate === page);
}

export function defaultSystemPage(setupRequired) {
  return setupRequired ? "project" : "overview";
}

export function systemPageLabel(page) {
  return systemPages.find(([candidate]) => candidate === page)?.[1] ?? "概览";
}

export function createSystemNavigationColumn({ selectedPage, onSelect }) {
  const column = document.createElement("div");
  const section = document.createElement("section");
  const heading = document.createElement("h2");
  const list = document.createElement("ul");
  column.className = "finder-column";
  column.id = "finder-column-system";
  column.dataset.depth = "1";
  column.setAttribute("role", "group");
  column.setAttribute("aria-label", "系统设置");
  section.className = "column-section";
  heading.className = "column-label";
  heading.textContent = "System";
  list.className = "column-list";

  for (const [page, label, summaryText] of systemPages) {
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
    button.dataset.kind = "system-page";
    button.dataset.page = page;
    button.dataset.navigationKey = `__system__.${page}`;
    if (selectedPage === page) {
      button.setAttribute("aria-current", "page");
    }
    icon.className = "row-icon";
    icon.textContent = page === "overview" ? "i" : "·";
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
  return column;
}
