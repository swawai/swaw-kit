import { describe, expect, test } from "bun:test";

import { commandMenuId, commandMenuPosition } from "./command-menu-position.js";

describe("Explorer command menu placement", () => {
  test("opens beside its command without participating in column layout", () => {
    expect(commandMenuPosition(
      { left: 8, right: 284, top: 299 },
      { height: 88, width: 180 },
      { height: 720, width: 1280 },
    )).toEqual({ left: 288, top: 299 });
  });

  test("flips and clamps the menu at viewport edges", () => {
    expect(commandMenuPosition(
      { left: 620, right: 700, top: 680 },
      { height: 100, width: 180 },
      { height: 720, width: 720 },
    )).toEqual({ left: 436, top: 612 });
    expect(commandMenuPosition(
      { left: 4, right: 60, top: -10 },
      { height: 80, width: 120 },
      { height: 720, width: 160 },
    )).toEqual({ left: 8, top: 8 });
  });

  test("derives stable DOM ids from command identity and depth", () => {
    expect(commandMenuId(".dev/rust", 2)).toBe(
      "command-facet-menu-2-.dev%2Frust",
    );
  });
});
