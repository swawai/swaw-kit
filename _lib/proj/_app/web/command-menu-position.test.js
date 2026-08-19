import { describe, expect, test } from "bun:test";

import {
  commandMenuHorizontalBounds,
  commandMenuId,
  commandMenuPosition,
} from "./command-menu-position.js";

describe("Explorer command menu placement", () => {
  test("right-aligns below its command just before the next Finder column", () => {
    expect(commandMenuPosition(
      { bottom: 217, left: 8, right: 284, top: 174 },
      { height: 88, width: 128 },
      { left: 0, right: 292 },
      { left: 292, right: 584 },
      { height: 720, width: 1280 },
    )).toEqual({ left: 158, top: 221 });
    expect(commandMenuHorizontalBounds(
      { left: 0, right: 292 },
      { left: 292, right: 584 },
      { width: 1280 },
    )).toEqual({ left: 8, maxWidth: 278, right: 286 });
  });

  test("uses an existing column gap and flips above at the viewport edge", () => {
    expect(commandMenuHorizontalBounds(
      { left: 0, right: 292 },
      { left: 300, right: 592 },
      { width: 1280 },
    )).toEqual({ left: 8, maxWidth: 286, right: 294 });
    expect(commandMenuPosition(
      { bottom: 712, left: 608, right: 712, top: 680 },
      { height: 100, width: 104 },
      { left: 600, right: 720 },
      null,
      { height: 720, width: 720 },
    )).toEqual({ left: 608, top: 576 });
    expect(commandMenuPosition(
      { bottom: 30, left: 4, right: 60, top: -10 },
      { height: 80, width: 120 },
      { left: 0, right: 160 },
      null,
      { height: 720, width: 160 },
    )).toEqual({ left: 32, top: 34 });
  });

  test("derives stable DOM ids from command identity and depth", () => {
    expect(commandMenuId(".dev/rust", 2)).toBe(
      "command-facet-menu-2-.dev%2Frust",
    );
  });
});
