import { describe, expect, test } from "bun:test";

import {
  ENTRY_INSTANCE_MUTATION_PROTOCOL,
  ENTRY_INSTANCE_STATE_PROTOCOL,
  ENTRY_INVENTORY_PROTOCOL,
  EntryManagerProtocolError,
  normalizeEntryInspection,
  normalizeEntryInventory,
  normalizeEntryMutation,
  previewEntryPaths,
} from "./entry-manager-model.js";

function entry(overrides = {}) {
  return {
    entryName: "proj1",
    entryFile: "D:\\kit\\proj1.exe",
    dataRoot: "D:\\kit\\data\\proj.proj1",
    status: "ready",
    entryId: "a".repeat(64),
    releaseId: "b".repeat(64),
    issues: [],
    ...overrides,
  };
}

describe("Entry manager protocol model", () => {
  test("normalizes the exact inventory and preserves state", () => {
    const document = {
      protocol: ENTRY_INVENTORY_PROTOCOL,
      swawkitHome: "D:\\kit",
      entries: [entry()],
    };
    expect(normalizeEntryInventory(document)).toEqual(document);
  });

  test("rejects old, extended, duplicate, and malformed inventory state", () => {
    const valid = {
      protocol: ENTRY_INVENTORY_PROTOCOL,
      swawkitHome: "D:\\kit",
      entries: [entry()],
    };
    const invalid = [
      { ...valid, protocol: "swawkit.entry-inventory/v0" },
      { ...valid, extra: true },
      { ...valid, entries: [entry(), entry()] },
      { ...valid, entries: [{ ...entry(), extra: true }] },
      { ...valid, entries: [entry({ status: "unknown" })] },
      { ...valid, entries: [entry({ entryId: "invalid" })] },
      { ...valid, entries: [entry({ issues: [""] })] },
    ];
    for (const document of invalid) {
      expect(() => normalizeEntryInventory(document)).toThrow(EntryManagerProtocolError);
    }
  });

  test("binds inspections and mutations to the requested Entry and operation", () => {
    const inspection = {
      protocol: ENTRY_INSTANCE_STATE_PROTOCOL,
      entry: entry({ status: "available", entryId: null, releaseId: null }),
    };
    expect(normalizeEntryInspection(inspection, "proj1")).toEqual(inspection);
    expect(() => normalizeEntryInspection(inspection, "proj2"))
      .toThrow("different Entry name");

    const mutation = {
      protocol: ENTRY_INSTANCE_MUTATION_PROTOCOL,
      operation: "create",
      changed: true,
      entry: entry(),
    };
    expect(normalizeEntryMutation(mutation, "create", "proj1")).toEqual(mutation);
    expect(() => normalizeEntryMutation(mutation, "migrate", "proj1"))
      .toThrow("different operation");
    expect(() => normalizeEntryMutation({ ...mutation, unexpected: true }, "create"))
      .toThrow(EntryManagerProtocolError);
  });

  test("projects only canonical first-slice Entry names", () => {
    expect(previewEntryPaths("D:\\kit", "proj1-alpha")).toEqual({
      entryFile: "D:\\kit\\proj1-alpha.exe",
      dataRoot: "D:\\kit\\data\\proj.proj1-alpha",
    });
    expect(previewEntryPaths("/kit/", "proj2")).toEqual({
      entryFile: "/kit/proj2.exe",
      dataRoot: "/kit/data/proj.proj2",
    });
    for (const name of [
      "swawkit",
      "con",
      "prn",
      "aux",
      "nul",
      "com1",
      "com9",
      "lpt1",
      "lpt9",
      "Proj1",
      "1proj",
      "proj--one",
      "proj_1",
      "proj.exe",
      `p${"a".repeat(48)}`,
    ]) {
      expect(previewEntryPaths("D:\\kit", name)).toBeNull();
    }
  });
});
