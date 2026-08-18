const VIEWPORT_MARGIN = 8;
const MENU_GAP = 4;

export function commandMenuId(address, depth) {
  return `command-facet-menu-${depth}-${encodeURIComponent(address)}`;
}

export function commandMenuPosition(anchorRect, menuRect, viewport) {
  const right = anchorRect.right + MENU_GAP;
  const left = right + menuRect.width <= viewport.width - VIEWPORT_MARGIN
    ? right
    : Math.max(
      VIEWPORT_MARGIN,
      anchorRect.left - menuRect.width - MENU_GAP,
    );
  const top = Math.max(
    VIEWPORT_MARGIN,
    Math.min(
      anchorRect.top,
      viewport.height - menuRect.height - VIEWPORT_MARGIN,
    ),
  );
  return { left, top };
}

export function positionCommandMenu(menu, anchor) {
  const position = commandMenuPosition(
    anchor.getBoundingClientRect(),
    menu.getBoundingClientRect(),
    { height: window.innerHeight, width: window.innerWidth },
  );
  menu.style.left = `${position.left}px`;
  menu.style.top = `${position.top}px`;
}
