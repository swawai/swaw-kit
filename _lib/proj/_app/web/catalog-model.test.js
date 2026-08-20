import { describe, expect, test } from "bun:test";
import {
  childrenOf,
  createCatalog,
  isGroup,
  sortCommands,
} from "./catalog-model.js";
import { node, payload } from "./catalog-model-fixture.js";

describe("Catalog v19 model", () => {
  test("derives a non-runnable group only from its children", () => {
    const catalog = createCatalog(payload([
      node(".dev"),
      node(".dev/setup", {
        parent: ".dev",
        runnable: true,
        entry: "run.ps1",
        adapter: "pwsh",
      }),
    ]));
    const group = catalog.commandByAddress.get(".dev");

    expect(group.runnable).toBe(false);
    expect(isGroup(catalog, group)).toBe(true);
    expect(childrenOf(catalog, group.address).map(({ address }) => address))
      .toEqual([".dev/setup"]);
  });

  test("keeps runnable capability independent from group capability", () => {
    const catalog = createCatalog(payload([
      node(".tool", {
        runnable: true,
        entry: "run.exe",
        adapter: "exe",
      }),
      node(".tool/status", {
        parent: ".tool",
        runnable: true,
        entry: "run.ps1",
        adapter: "pwsh",
      }),
    ]));
    const group = catalog.commandByAddress.get(".tool");

    expect(group.runnable).toBe(true);
    expect(isGroup(catalog, group)).toBe(true);
  });

  test("sorts sibling commands by address regardless of group capability", () => {
    const catalog = createCatalog(payload([
      node(".dev"),
      node(".dev/git", { parent: ".dev" }),
      node(".dev/git/name", { parent: ".dev/git" }),
      node(".dev/apply", { parent: ".dev" }),
      node(".dev/project", { parent: ".dev" }),
      node(".dev/project/root", { parent: ".dev/project" }),
      node(".dev/language", { parent: ".dev" }),
    ]));

    expect(sortCommands(catalog, childrenOf(catalog, ".dev")).map(({ address }) => address))
      .toEqual([
        ".dev/apply",
        ".dev/git",
        ".dev/language",
        ".dev/project",
      ]);
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

  test("keeps an invalid execution declaration local to its diagnostic command", () => {
    const catalog = createCatalog(payload([
      node("swaw/broken", {
        module: {
          schema: "swawkit.command-module/v11",
          execution: {
            type: "delegate",
            owner: {
              type: "command",
              space: "module",
              namespace: "swaw",
              address: "swaw/missing",
            },
          },
          requires: [],
          provides: [],
        },
        diagnostic: "delegated execution owner is missing",
      }),
    ]));

    expect(catalog.commandByAddress.get("swaw/broken").issue)
      .toBe("delegated execution owner is missing");
  });

  test("keeps runnable capability independent from diagnostics", () => {
    const catalog = createCatalog(payload([
      node(".documented", {
        runnable: true,
        entry: "run.ps1",
        adapter: "pwsh",
        diagnostic: "help file is empty",
      }),
    ]));
    const command = catalog.commandByAddress.get(".documented");

    expect(command.runnable).toBe(true);
    expect(command.issue).toBe("help file is empty");
  });

  test("rejects the previous Catalog v18 protocol", () => {
    expect(() => createCatalog(payload([], { protocol: "swawkit.command-catalog/v18" })))
      .toThrow("protocol 必须是 swawkit.command-catalog/v19");
  });

  test("normalizes the parent-owned child column width", () => {
    const catalog = createCatalog(payload([
      node(".dev/rust", {
        view: { childrenColumn: { width: "wide" } },
      }),
    ]));

    expect(catalog.commandByAddress.get(".dev/rust").childrenColumnWidth)
      .toBe("wide");
    expect(() => createCatalog(payload([
      node(".broken", {
        view: { childrenColumn: { width: "480px" } },
      }),
    ]))).toThrow("width 只能是 normal 或 wide");
  });

  test("normalizes fixed Web run operations and rejects ambiguous declarations", () => {
    const catalog = createCatalog(payload([
      node("maintenance/cleanup", {
        runnable: true,
        entry: "run.ps1",
        adapter: "pwsh",
        view: {
          run: {
            operations: [
              { id: "preview", label: "预览", arguments: [] },
              {
                id: "apply",
                label: "清理",
                arguments: ["--apply"],
                confirmation: "确认清理？",
              },
            ],
          },
        },
      }),
    ]));

    expect(catalog.commandByAddress.get("maintenance/cleanup").runOperations)
      .toEqual([
        { id: "preview", label: "预览", arguments: [], confirmation: null },
        {
          id: "apply",
          label: "清理",
          arguments: ["--apply"],
          confirmation: "确认清理？",
        },
      ]);
    expect(() => createCatalog(payload([
      node(".broken", {
        view: {
          run: {
            operations: [
              { id: "apply", label: "清理", arguments: [] },
              { id: "apply", label: "再次清理", arguments: [] },
            ],
          },
        },
      }),
    ]))).toThrow("id 必须唯一");
  });

  test("normalizes a command-resolved Subject collection Facet", () => {
    const catalog = createCatalog(payload([
      node(".context/list", {
        runnable: true,
        entry: "run.ps1",
        adapter: "pwsh",
      }),
      node(".context", {
        subjectKinds: [{
          kind: "context",
          facets: [{
            id: "overview",
            kind: "projection",
            renderer: "overview",
            icon: "i",
            label: "概览",
            summary: "查看 Context",
            resolver: {
              type: "command",
              address: ".context/list",
              arguments: [{ bind: "subject.id" }],
              returns: "swawkit.context/v2",
            },
          }],
        }],
        facets: [{
          id: "contexts",
          kind: "collection",
          renderer: "collection",
          icon: "◆",
          label: "上下文",
          summary: "浏览持久化的 Agent 上下文",
          resolver: {
            type: "command",
            address: ".context/list",
            arguments: ["--json"],
            returns: "swawkit.subject-collection/v3",
          },
          subjectKind: {
            kind: "context",
            provider: {
              type: "command",
              space: "system",
              address: ".context",
            },
          },
        }],
      }),
    ]));

    const context = catalog.commandByAddress.get(".context");
    expect(context.facets[0].resolver).toEqual({
      acceptsTail: false,
      address: ".context/list",
      arguments: ["--json"],
      confirmation: null,
      returns: "swawkit.subject-collection/v3",
      type: "command",
    });
  });

  test("resolves a collection through an explicit cross-command Subject kind provider", () => {
    const runs = {
      kind: "run",
      facets: [{
        id: "overview",
        kind: "projection",
        renderer: "overview",
        icon: "i",
        label: "Overview",
        summary: "Inspect Run",
        resolver: {
          type: "command",
          address: ".runs",
          arguments: [{ bind: "subject.id" }],
          returns: "swawkit.command-run-journal/v3",
        },
      }],
    };
    const runsFacet = {
      id: "runs",
      kind: "collection",
      renderer: "collection",
      icon: "=",
      label: "Runs",
      summary: "Browse Runs",
      resolver: {
        type: "command",
        address: ".runs",
        arguments: ["--json", ".tool"],
        returns: "swawkit.subject-collection/v3",
      },
      subjectKind: {
        kind: "run",
        provider: { type: "command", space: "system", address: ".runs" },
      },
    };
    const catalog = createCatalog(payload([
      node(".runs", {
        runnable: true,
        entry: "swawkit.module.json",
        adapter: "core",
        handler: "meta.runs",
        subjectKinds: [runs],
      }),
      node(".tool", {
        runnable: true,
        entry: "run.cmd",
        adapter: "cmd",
        facets: [runsFacet],
      }),
    ]));

    expect(catalog.commandByAddress.get(".tool").facets[0].subjectKind.provider.address)
      .toBe(".runs");

    const missingProvider = structuredClone(runsFacet);
    missingProvider.subjectKind.provider.address = ".tool";
    expect(() => createCatalog(payload([
      node(".runs", {
        runnable: true,
        entry: "swawkit.module.json",
        adapter: "core",
        handler: "meta.runs",
        subjectKinds: [runs],
      }),
      node(".tool", {
        runnable: true,
        entry: "run.cmd",
        adapter: "cmd",
        facets: [missingProvider],
      }),
    ]))).toThrow("unavailable Subject kind");
  });

  test("normalizes resolved Facets with exact CLI commands", () => {
    const catalog = createCatalog(payload([
      node(".check", {
        runnable: true,
        entry: "swawkit.module.json",
        adapter: "core",
        handler: "meta.check",
      }),
      node(".context/list", {
        facets: [
          {
            id: "check",
            kind: "projection",
            renderer: "overview",
            icon: "!",
            label: "检查",
            summary: "检查模块",
            resolver: {
              type: "command",
              address: ".check",
              arguments: [".context/list", "--json"],
              returns: "swawkit.command-check/v2",
            },
          },
        ],
      }),
    ]));

    const facets = catalog.commandByAddress.get(".context/list").facets;
    expect(facets[0].id).toBe("check");
    expect(facets[0].resolver).toEqual({
      acceptsTail: false,
      address: ".check",
      arguments: [".context/list", "--json"],
      confirmation: null,
      returns: "swawkit.command-check/v2",
      type: "command",
    });
    expect(() => createCatalog(payload([
      node(".context/list", {
        facets: [{
          id: "check",
          kind: "operation",
          renderer: "run",
          icon: "!",
          label: "检查",
          summary: "检查模块",
          resolver: { type: "command", address: ".missing", arguments: [] },
        }],
      }),
    ]))).toThrow("引用了不存在的命令");
  });
});
