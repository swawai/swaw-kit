import { describe, expect, test } from "bun:test";
import {
  childrenOf,
  createCatalog,
  isGroup,
} from "./catalog-model.js";

const protocol = "swawkit.command-catalog/v1";

function node(address, overrides = {}) {
  return {
    address,
    source: "kernel",
    parent: "",
    aliasOf: null,
    runnable: false,
    entry: null,
    adapter: null,
    help: null,
    diagnostic: null,
    ...overrides,
  };
}

function payload(commands, overrides = {}) {
  return {
    protocol,
    entryName: "swawkit",
    commands,
    ...overrides,
  };
}

describe("Catalog v1 model", () => {
  test("derives a non-runnable group only from its children", () => {
    const catalog = createCatalog(payload([
      node(".dev"),
      node(".dev.setup", {
        parent: ".dev",
        runnable: true,
        entry: "run.ps1",
        adapter: "powershell",
      }),
    ]));
    const group = catalog.commandByAddress.get(".dev");

    expect(group.runnable).toBe(false);
    expect(isGroup(catalog, group)).toBe(true);
    expect(childrenOf(catalog, group.address).map(({ address }) => address))
      .toEqual([".dev.setup"]);
  });

  test("keeps runnable capability independent from group capability", () => {
    const catalog = createCatalog(payload([
      node(".tool", {
        runnable: true,
        entry: "run.exe",
        adapter: "exe",
      }),
      node(".tool.status", {
        parent: ".tool",
        runnable: true,
        entry: "run.ps1",
        adapter: "powershell",
      }),
    ]));
    const group = catalog.commandByAddress.get(".tool");

    expect(group.runnable).toBe(true);
    expect(isGroup(catalog, group)).toBe(true);
  });

  test("keeps a diagnostic leaf distinct from a command group", () => {
    const catalog = createCatalog(payload([
      node(".broken", { diagnostic: "multiple run entries" }),
    ]));
    const command = catalog.commandByAddress.get(".broken");

    expect(command.issue).toBe("multiple run entries");
    expect(command.runnable).toBe(false);
    expect(isGroup(catalog, command)).toBe(false);
  });

  test("keeps runnable capability independent from diagnostics", () => {
    const catalog = createCatalog(payload([
      node(".documented", {
        runnable: true,
        entry: "run.ps1",
        adapter: "powershell",
        diagnostic: "help file is empty",
      }),
    ]));
    const command = catalog.commandByAddress.get(".documented");

    expect(command.runnable).toBe(true);
    expect(command.issue).toBe("help file is empty");
  });

  test("rejects an unknown protocol version", () => {
    expect(() => createCatalog(payload([], { protocol: "catalog/v2" })))
      .toThrow("protocol 必须是 swawkit.command-catalog/v1");
  });

  test("rejects a missing entry name", () => {
    const document = payload([]);
    delete document.entryName;

    expect(() => createCatalog(document)).toThrow("entryName 必须是非空字符串");
  });

  test("rejects inconsistent runnable entry fields", () => {
    expect(() => createCatalog(payload([
      node(".broken", { runnable: true }),
    ]))).toThrow("runnable 必须与 entry 是否存在一致");

    expect(() => createCatalog(payload([
      node(".broken", { adapter: "powershell" }),
    ]))).toThrow("adapter 必须与 entry 同时存在或同时为空");
  });

  test("rejects sources outside the v1 kernel/action vocabulary", () => {
    expect(() => createCatalog(payload([
      node(".legacy", { source: "project" }),
    ]))).toThrow("source 只能是 kernel 或 action");
  });
});
