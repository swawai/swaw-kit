import { describe, expect, test } from "bun:test";

import {
  captureColumnScrollOffsets,
  commandDisabledDuringSetup,
  controlledColumnId,
  restoreColumnScrollOffsets,
} from "./explorer.js";

describe("Explorer control-plane behavior", () => {
  test("keeps Control commands available during first setup", () => {
    expect(commandDisabledDuringSetup(true, { source: "control" })).toBe(false);
    expect(commandDisabledDuringSetup(true, { source: "kernel" })).toBe(true);
    expect(commandDisabledDuringSetup(true, { source: "action" })).toBe(true);
    expect(commandDisabledDuringSetup(false, { source: "action" })).toBe(false);
  });

  test("connects command rows to the column they actually reveal", () => {
    expect(controlledColumnId({ handler: "entry.profile" }, 0))
      .toBe("finder-column-1");
    expect(controlledColumnId({ handler: "host.start" }, 0))
      .toBe("finder-column-1");
  });

  test("restores vertical offsets only for columns representing the same parent", () => {
    let rendered = [
      { dataset: { scrollKey: "root" }, scrollTop: 17 },
      { dataset: { scrollKey: "children:..entry.env" }, scrollTop: 559 },
    ];
    const columns = {
      querySelectorAll() {
        return rendered;
      },
    };
    const offsets = captureColumnScrollOffsets(columns);

    rendered = [
      { dataset: { scrollKey: "root" }, scrollTop: 0 },
      { dataset: { scrollKey: "children:..entry.env" }, scrollTop: 0 },
      { dataset: { scrollKey: "children:proj" }, scrollTop: 0 },
    ];
    restoreColumnScrollOffsets(columns, offsets);

    expect(rendered.map((column) => column.scrollTop)).toEqual([17, 559, 0]);
  });
});
