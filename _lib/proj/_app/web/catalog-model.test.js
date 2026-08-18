import { describe, expect, test } from "bun:test";
import {
  childrenOf,
  createCatalog,
  isGroup,
  sortCommands,
} from "./catalog-model.js";

const protocol = "swawkit.command-catalog/v17";

function node(address, overrides = {}) {
  const space = overrides.space ?? (address.startsWith(".") || address === "" ? "system" : "module");
  const namespace = space === "module"
    ? overrides.namespace ?? address.split("/")[0]
    : null;
  const path = space === "system"
    ? address === "" ? [] : address.slice(1).split("/")
    : space === "module"
      ? address === namespace ? [] : address.slice(namespace.length + 1).split("/")
      : [];
  const command = {
    address,
    space,
    namespace,
    path,
    parent: "",
    aliasOf: null,
    runnable: false,
    entry: null,
    adapter: null,
    handler: null,
    product: null,
    module: null,
    help: null,
    subjectKinds: [],
    facets: [],
    view: null,
    diagnostic: null,
    ...overrides,
  };
  if (
    command.module === null
    && new Set(["core", "toolchain", "runtime", "native"]).has(command.adapter)
  ) {
    command.module = {
      schema: "swawkit.command-module/v9",
      execution: command.adapter === "native"
        ? { type: "native" }
        : command.adapter === "runtime"
          ? { type: "runtime", product: command.product }
          : { type: command.adapter, handler: command.handler },
      requires: [],
      provides: [],
    };
  }
  return command;
}

function payload(commands, overrides = {}) {
  return {
    protocol,
    entryName: "swawkit",
    language: "zh-CN",
    commands,
    ...overrides,
  };
}

describe("Catalog v17 model", () => {
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

  test("keeps typed Profile settings and their ancestors available during setup", () => {
    const catalog = createCatalog(payload([
      node(".dev"),
      node(".dev/bun", { parent: ".dev" }),
      node(".dev/bun/mode", {
        parent: ".dev/bun",
        runnable: true,
        entry: "swawkit.module.json",
        adapter: "core",
        handler: "entry.profile.set",
      }),
      node(".dev/exec", { parent: ".dev" }),
    ]));

    expect(catalog.commandByAddress.get(".dev").setupAvailable).toBe(true);
    expect(catalog.commandByAddress.get(".dev/bun").setupAvailable).toBe(true);
    expect(catalog.commandByAddress.get(".dev/bun/mode").setupAvailable).toBe(true);
    expect(catalog.commandByAddress.get(".dev/exec").setupAvailable).toBe(false);
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
          schema: "swawkit.command-module/v9",
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

  test("rejects an unknown protocol version", () => {
    expect(() => createCatalog(payload([], { protocol: "catalog/v2" })))
      .toThrow("protocol 必须是 swawkit.command-catalog/v17");
  });

  test("normalizes declared module requirements and provisions", () => {
    const catalog = createCatalog(payload([
      node(".consumer", {
        module: {
          schema: "swawkit.command-module/v9",
          requires: [{
            provider: ".provider",
            export: "fixture",
            contract: "swawkit.fixture/v1",
          }],
          provides: [{ id: "consumer", contract: "swawkit.consumer/v1" }],
        },
      }),
    ]));
    expect(catalog.commandByAddress.get(".consumer").module).toEqual({
      schema: "swawkit.command-module/v9",
      execution: null,
      requires: [{
        provider: ".provider",
        export: "fixture",
        contract: "swawkit.fixture/v1",
      }],
      provides: [{ id: "consumer", contract: "swawkit.consumer/v1" }],
    });
  });

  test("normalizes explicit delegated execution", () => {
    const catalog = createCatalog(payload([
      node("swaw/context/add", {
        runnable: true,
        entry: "swawkit.module.json",
        adapter: "delegate",
        module: {
          schema: "swawkit.command-module/v9",
          execution: {
            type: "delegate",
            owner: {
              type: "command",
              space: "module",
              namespace: "swaw",
              address: "swaw/context",
            },
          },
          requires: [],
          provides: [],
        },
      }),
    ]));

    expect(catalog.commandByAddress.get("swaw/context/add").module.execution).toEqual({
      type: "delegate",
      owner: {
        type: "command",
        space: "module",
        namespace: "swaw",
        address: "swaw/context",
      },
    });
  });

  test("normalizes native execution without a marker file", () => {
    const catalog = createCatalog(payload([
      node("swaw/native", {
        runnable: true,
        entry: "swawkit.module.json",
        adapter: "native",
      }),
    ]));

    expect(catalog.commandByAddress.get("swaw/native").module.execution)
      .toEqual({ type: "native" });
  });

  test("rejects the removed command-module/v8 contract", () => {
    expect(() => createCatalog(payload([
      node(".legacy", {
        module: {
          schema: "swawkit.command-module/v8",
          requires: [],
          provides: [{ contract: "legacy/v1" }],
        },
      }),
    ]))).toThrow("swawkit.command-module/v9");
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
      node(".broken", { adapter: "pwsh" }),
    ]))).toThrow("adapter 必须与 entry 同时存在或同时为空");

    expect(() => createCatalog(payload([
      node("swaw/broken", {
        runnable: true,
        entry: "run.ps1",
        adapter: "pwsh",
        module: {
          schema: "swawkit.command-module/v9",
          execution: { type: "native" },
          requires: [],
          provides: [],
        },
      }),
    ]))).toThrow("module execution declaration");
  });

  test("accepts System commands and rejects unknown spaces", () => {
    const catalog = createCatalog(payload([
      node(".entry", {
        space: "system",
        runnable: true,
        entry: "swawkit.module.json",
        adapter: "core",
        handler: "entry.profile",
      }),
    ]));
    expect(catalog.commandByAddress.get(".entry").handler)
      .toBe("entry.profile");

    expect(() => createCatalog(payload([
      node(".legacy", { space: "project" }),
    ]))).toThrow("space must be system or module");
  });

  test("allows the dedicated edit renderer to target a typed System setting", () => {
    const address = ".entry/language";
    const catalog = createCatalog(payload([
      node(address, {
        space: "system",
        runnable: true,
        entry: "swawkit.module.json",
        adapter: "core",
        handler: "entry.profile.set",
        facets: [{
          id: "edit",
          kind: "operation",
          renderer: "edit",
          icon: "*",
          label: "Language",
          summary: "Set language",
          resolver: { type: "command", address, arguments: [] },
        }],
      }),
    ]));
    expect(catalog.commandByAddress.get(address).facets[0].renderer).toBe("edit");
  });

  test("accepts handlers owned by core and toolchain adapters only", () => {
    const catalog = createCatalog(payload([
      node(".dev/setup", {
        runnable: true,
        entry: "swawkit.module.json",
        adapter: "toolchain",
        handler: "dev.setup",
      }),
    ]));
    expect(catalog.commandByAddress.get(".dev/setup").handler)
      .toBe("dev.setup");

    expect(() => createCatalog(payload([
      node(".broken", {
        runnable: true,
        entry: "swawkit.module.json",
        adapter: "toolchain",
      }),
    ]))).toThrow("handler");
    expect(() => createCatalog(payload([
      node(".broken", {
        runnable: true,
        entry: "run.ps1",
        adapter: "pwsh",
        handler: "dev.setup",
      }),
    ]))).toThrow("handler");
  });

  test("normalizes the exact module Runtime Component without a handler", () => {
    const catalog = createCatalog(payload([
      node(".module/status", {
        parent: ".module",
        runnable: true,
        entry: "swawkit.module.json",
        adapter: "runtime",
        product: "module",
      }),
    ]));
    const status = catalog.commandByAddress.get(".module/status");

    expect(status.handler).toBe("");
    expect(status.product).toBe("module");
    expect(status.module.execution).toEqual({
      type: "runtime",
      product: "module",
    });

    expect(() => createCatalog(payload([
      node(".module/status", {
        runnable: true,
        entry: "swawkit.module.json",
        adapter: "runtime",
        product: "toolchain",
      }),
    ]))).toThrow("runtime product module is restricted");
    expect(() => createCatalog(payload([
      node(".wrong", {
        runnable: true,
        entry: "swawkit.module.json",
        adapter: "runtime",
        product: "module",
      }),
    ]))).toThrow("runtime product module is restricted");
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
      node("swaw/context/list", {
        runnable: true,
        entry: "run.ps1",
        adapter: "pwsh",
      }),
      node("swaw/context", {
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
              address: "swaw/context/list",
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
            address: "swaw/context/list",
            arguments: ["--json"],
            returns: "swawkit.subject-collection/v3",
          },
          subjectKind: {
            kind: "context",
            provider: {
              type: "command",
              space: "module",
              namespace: "swaw",
              address: "swaw/context",
            },
          },
        }],
      }),
    ]));

    const context = catalog.commandByAddress.get("swaw/context");
    expect(context.facets[0].resolver).toEqual({
      acceptsTail: false,
      address: "swaw/context/list",
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
          returns: "swawkit.command-run-journal/v2",
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
      node("swaw/context/list", {
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
              arguments: ["swaw/context/list", "--json"],
              returns: "swawkit.command-check/v1",
            },
          },
        ],
      }),
    ]));

    const facets = catalog.commandByAddress.get("swaw/context/list").facets;
    expect(facets[0].id).toBe("check");
    expect(facets[0].resolver).toEqual({
      acceptsTail: false,
      address: ".check",
      arguments: ["swaw/context/list", "--json"],
      confirmation: null,
      returns: "swawkit.command-check/v1",
      type: "command",
    });
    expect(() => createCatalog(payload([
      node("swaw/context/list", {
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
