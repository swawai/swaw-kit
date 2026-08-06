import { describe, expect, test } from "bun:test";

import {
  defaultEntryPage,
  entryPageLabel,
  entryPages,
  isEntryPage,
} from "./entry-navigation.js";

describe("Entry Profile navigation", () => {
  test("keeps each settings page address unique", () => {
    const addresses = entryPages.map(({ id }) => id);
    expect(new Set(addresses).size).toBe(addresses.length);
  });

  test("recognizes only declared pages and renders a stable label", () => {
    expect(isEntryPage("development")).toBe(true);
    expect(isEntryPage("overview")).toBe(false);
    expect(entryPageLabel("git")).toBe("Git 与仓库");
    expect(entryPageLabel("unknown")).toBe("项目绑定");
  });

  test("always enters through project binding", () => {
    expect(defaultEntryPage()).toBe("project");
  });
});
