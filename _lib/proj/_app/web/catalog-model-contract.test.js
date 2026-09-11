import { describe, expect, test } from "bun:test";
import { createCatalog } from "./catalog-model.js";
import { node, payload } from "./catalog-model-fixture.js";

describe("Catalog v24 runtime facts", () => {
  test("does not expose an authoring manifest projection", () => {
    const catalog = createCatalog(payload([
      node(".consumer"),
    ]));

    expect(catalog.commandByAddress.get(".consumer").module).toBeUndefined();
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
  });

  test("accepts System commands and rejects unknown spaces", () => {
    const catalog = createCatalog(payload([
      node(".entry", {
        space: "system",
        runnable: true,
        entry: "swawkit.execution.json",
        adapter: "core",
        handler: "entry.config",
      }),
    ]));
    expect(catalog.commandByAddress.get(".entry").handler).toBe("entry.config");

    expect(() => createCatalog(payload([
      node(".legacy", { space: "project" }),
    ]))).toThrow("space must be system or module");
  });

  test("keeps adapter-specific runtime facts exact", () => {
    const catalog = createCatalog(payload([
      node(".module/status", {
        parent: ".module",
        runnable: true,
        entry: "swawkit.execution.json",
        adapter: "runtime",
        product: "module",
      }),
    ]));
    const status = catalog.commandByAddress.get(".module/status");

    expect(status.handler).toBe("");
    expect(status.product).toBe("module");
    expect(() => createCatalog(payload([
      node(".wrong", {
        runnable: true,
        entry: "swawkit.execution.json",
        adapter: "runtime",
        product: "module",
      }),
    ]))).toThrow("runtime product is not valid");
  });
});
