import { describe, expect, test } from "bun:test";

import {
  defaultSystemPage,
  isSystemPage,
  systemPageLabel,
  systemPages,
} from "./system-navigation.js";

describe("System navigation", () => {
  test("keeps each settings page address unique", () => {
    const addresses = systemPages.map(([address]) => address);
    expect(new Set(addresses).size).toBe(addresses.length);
  });

  test("recognizes only declared pages and renders a stable label", () => {
    expect(isSystemPage("development")).toBe(true);
    expect(isSystemPage("setup")).toBe(false);
    expect(systemPageLabel("git")).toBe("Git 与仓库");
    expect(systemPageLabel("unknown")).toBe("概览");
  });

  test("uses project binding as the first setup page without changing the column model", () => {
    expect(defaultSystemPage(true)).toBe("project");
    expect(defaultSystemPage(false)).toBe("overview");
  });
});
