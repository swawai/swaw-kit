const VIEWPORT_MARGIN = 8;
const MENU_GAP = 4;
const COLUMN_INSET = 8;
const NEXT_COLUMN_GAP = 6;

export function commandMenuId(address, depth) {
  return `command-facet-menu-${depth}-${encodeURIComponent(address)}`;
}

export function commandMenuHorizontalBounds(
  columnRect,
  nextColumnRect,
  viewport,
) {
  const left = Math.max(VIEWPORT_MARGIN, columnRect.left + COLUMN_INSET);
  const nextColumnLeft = nextColumnRect?.left ?? columnRect.right;
  const right = Math.min(
    nextColumnLeft - NEXT_COLUMN_GAP,
    viewport.width - VIEWPORT_MARGIN,
  );
  return {
    left,
    maxWidth: Math.max(0, right - left),
    right,
  };
}

export function commandMenuPosition(
  anchorRect,
  menuRect,
  columnRect,
  nextColumnRect,
  viewport,
) {
  const horizontal = commandMenuHorizontalBounds(
    columnRect,
    nextColumnRect,
    viewport,
  );
  const left = Math.max(horizontal.left, horizontal.right - menuRect.width);
  const below = anchorRect.bottom + MENU_GAP;
  const above = anchorRect.top - menuRect.height - MENU_GAP;
  const top = below + menuRect.height <= viewport.height - VIEWPORT_MARGIN
    ? below
    : Math.max(VIEWPORT_MARGIN, above);
  return { left, top };
}

export function positionCommandMenu(menu, anchor) {
  const column = anchor.closest(".finder-column");
  if (!column) {
    return;
  }
  const nextColumn = column.nextElementSibling?.matches(".finder-column")
    ? column.nextElementSibling
    : null;
  const columnRect = column.getBoundingClientRect();
  const nextColumnRect = nextColumn?.getBoundingClientRect() ?? null;
  const viewport = { height: window.innerHeight, width: window.innerWidth };
  const horizontal = commandMenuHorizontalBounds(
    columnRect,
    nextColumnRect,
    viewport,
  );
  menu.style.maxWidth = `${horizontal.maxWidth}px`;
  const position = commandMenuPosition(
    anchor.getBoundingClientRect(),
    menu.getBoundingClientRect(),
    columnRect,
    nextColumnRect,
    viewport,
  );
  menu.style.left = `${position.left}px`;
  menu.style.top = `${position.top}px`;
}
