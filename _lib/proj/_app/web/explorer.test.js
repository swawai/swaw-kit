import { describe, expect, test } from "bun:test";

import {
  commandDisabledDuringSetup,
  controlledColumnId,
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
});
