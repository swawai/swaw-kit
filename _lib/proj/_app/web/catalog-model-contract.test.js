import { describe, expect, test } from "bun:test";
import { createCatalog } from "./catalog-model.js";
import { node, payload } from "./catalog-model-fixture.js";

describe("Catalog v19 execution contract", () => {
  test("normalizes declared module requirements and provisions", () => {
    const catalog = createCatalog(payload([
      node(".consumer", {
        module: {
          schema: "swawkit.command-module/v11",
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
      schema: "swawkit.command-module/v11",
      execution: null,
      requires: [{
        provider: ".provider",
        export: "fixture",
        contract: "swawkit.fixture/v1",
      }],
      provides: [{ id: "consumer", contract: "swawkit.consumer/v1" }],
    });
  });

  test("normalizes explicit System delegated execution", () => {
    const catalog = createCatalog(payload([
      node(".context/add", {
        runnable: true,
        entry: "swawkit.module.json",
        adapter: "delegate",
        module: {
          schema: "swawkit.command-module/v11",
          execution: {
            type: "delegate",
            owner: {
              type: "command",
              space: "system",
              address: ".context",
            },
          },
          requires: [],
          provides: [],
        },
      }),
    ]));

    expect(catalog.commandByAddress.get(".context/add").module.execution).toEqual({
      type: "delegate",
      owner: {
        type: "command",
        space: "system",
        namespace: null,
        address: ".context",
      },
    });
  });

  test("keeps ordinary Module delegated execution", () => {
    const catalog = createCatalog(payload([
      node("acme/build/inspect", {
        runnable: true,
        entry: "swawkit.module.json",
        adapter: "delegate",
        module: {
          schema: "swawkit.command-module/v11",
          execution: {
            type: "delegate",
            owner: {
              type: "command",
              space: "module",
              namespace: "acme",
              address: "acme/build",
            },
          },
          requires: [],
          provides: [],
        },
      }),
    ]));

    expect(catalog.commandByAddress.get("acme/build/inspect").module.execution.owner)
      .toEqual({
        type: "command",
        space: "module",
        namespace: "acme",
        address: "acme/build",
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

  test("rejects the previous command-module/v10 contract", () => {
    expect(() => createCatalog(payload([
      node(".legacy", {
        module: {
          schema: "swawkit.command-module/v10",
          requires: [],
          provides: [{ contract: "legacy/v1" }],
        },
      }),
    ]))).toThrow("swawkit.command-module/v11");
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
          schema: "swawkit.command-module/v11",
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

  test("accepts handlers owned by the core adapter only", () => {
    expect(() => createCatalog(payload([
      node(".broken", {
        runnable: true,
        entry: "swawkit.module.json",
        adapter: "runtime",
        product: "dev",
        handler: "dev.setup",
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

  test("normalizes the exact Runtime Components without a handler", () => {
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
    ]))).toThrow("runtime product is not valid");
    expect(() => createCatalog(payload([
      node(".wrong", {
        runnable: true,
        entry: "swawkit.module.json",
        adapter: "runtime",
        product: "module",
      }),
    ]))).toThrow("runtime product is not valid");

    const dev = createCatalog(payload([
      node(".dev/setup", {
        parent: ".dev",
        runnable: true,
        entry: "swawkit.module.json",
        adapter: "runtime",
        product: "dev",
      }),
      node(".dev/setup/check", {
        parent: ".dev/setup",
        runnable: true,
        entry: "swawkit.module.json",
        adapter: "runtime",
        product: "dev",
      }),
    ]));
    expect(dev.commandByAddress.get(".dev/setup").product).toBe("dev");
    expect(dev.commandByAddress.get(".dev/setup/check").product).toBe("dev");
  });
});
