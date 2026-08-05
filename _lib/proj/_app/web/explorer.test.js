import { describe, expect, test } from "bun:test";

import {
  commandDisabledDuringSetup,
  controlledColumnId,
  findEntryProfileCommand,
} from "./explorer.js";

describe("Explorer control-plane behavior", () => {
  test("keeps Control commands available during first setup", () => {
    expect(commandDisabledDuringSetup(true, { source: "control" })).toBe(false);
    expect(commandDisabledDuringSetup(true, { source: "kernel" })).toBe(true);
    expect(commandDisabledDuringSetup(true, { source: "action" })).toBe(true);
    expect(commandDisabledDuringSetup(false, { source: "action" })).toBe(false);
  });

  test("finds the Entry Profile renderer by Control handler, not by display order", () => {
    const profile = {
      address: "..entry",
      handler: "entry.profile",
      source: "control",
    };
    const catalog = {
      roots: [
        { address: "..web", handler: "host.start", source: "control" },
        profile,
        { address: ".entry", handler: "entry.profile", source: "kernel" },
      ],
    };

    expect(findEntryProfileCommand(catalog)).toBe(profile);
    expect(findEntryProfileCommand({ roots: [] })).toBeNull();
  });

  test("connects command rows to the column they actually reveal", () => {
    expect(controlledColumnId({ handler: "entry.profile" }, 0))
      .toBe("finder-column-entry");
    expect(controlledColumnId({ handler: "host.start" }, 0))
      .toBe("finder-column-1");
  });
});
