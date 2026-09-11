import { positionCommandMenu } from "./command-menu-position.js";
import { t } from "./i18n.js";

export function commandMenuFor(columns, address) {
  return columns.querySelector(
    `.command-facet-popover[data-address="${CSS.escape(address)}"]`,
  );
}

export function commandMenuToggleFor(columns, address) {
  return columns.querySelector(
    `.command-menu-toggle[data-address="${CSS.escape(address)}"]`,
  );
}

export function setCommandMenuToggleState(toggle, address, expanded) {
  const label = expanded
    ? t(`收起 ${address} 能力菜单`, `Collapse ${address} facet menu`)
    : t(`展开 ${address} 能力菜单`, `Expand ${address} facet menu`);
  toggle.setAttribute("aria-expanded", String(expanded));
  toggle.setAttribute("aria-label", label);
  toggle.title = label;
}

export function showCommandMenu(columns, address, { focusFirst = false } = {}) {
  const menu = commandMenuFor(columns, address);
  const toggle = commandMenuToggleFor(columns, address);
  const anchor = toggle?.closest(".command-item")?.querySelector(".command-row");
  if (!menu || !toggle || !anchor) {
    return false;
  }
  setCommandMenuToggleState(toggle, address, true);
  if (!menu.matches(":popover-open")) {
    menu.showPopover();
  }
  positionCommandMenu(menu, anchor);
  if (focusFirst) {
    menu.querySelector(".command-facet-row")?.focus({ preventScroll: true });
  }
  return true;
}

export function closeCommandMenu(columns, address, { restoreFocus = false } = {}) {
  const menu = commandMenuFor(columns, address);
  const toggle = commandMenuToggleFor(columns, address);
  if (menu?.matches(":popover-open")) {
    menu.hidePopover();
  }
  if (toggle) {
    setCommandMenuToggleState(toggle, address, false);
    if (restoreFocus) {
      toggle.focus({ preventScroll: true });
    }
  }
}
