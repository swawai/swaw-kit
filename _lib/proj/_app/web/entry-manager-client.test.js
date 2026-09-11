import { describe, expect, test } from "bun:test";

import {
  EntryManagerClientError,
  createEntryInstance,
  inspectEntryInstance,
  migrateEntryInstance,
  readEntryInventory,
} from "./entry-manager-client.js";
import { RuntimeGenerationError } from "./runtime-generation.js";

function entry(status = "ready") {
  return {
    entryName: "proj1",
    entryFile: "D:\\kit\\proj1.exe",
    dataRoot: "D:\\kit\\data\\proj.proj1",
    status,
    releaseId: status === "ready" ? "b".repeat(64) : null,
    issues: [],
  };
}

function response(document, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => document,
  };
}

describe("Entry manager client", () => {
  test("reads the inventory without probing mutation routes", async () => {
    const requests = [];
    const document = {
      protocol: "swawkit.entry-inventory/v2",
      swawkitHome: "D:\\kit",
      entries: [entry()],
    };
    expect(await readEntryInventory(async (...request) => {
      requests.push(request);
      return response(document);
    })).toEqual(document);
    expect(requests).toEqual([["/api/v2/entries", {
      cache: "no-store",
      headers: { Accept: "application/json" },
    }]]);
  });

  test("uses the exact inspect request without a control header", async () => {
    const requests = [];
    const document = {
      protocol: "swawkit.entry-instance-state/v2",
      entry: entry("available"),
    };
    await inspectEntryInstance("proj1", async (...request) => {
      requests.push(request);
      return response(document);
    });
    expect(requests).toEqual([["/api/v2/entries/inspect", {
      method: "POST",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ entryName: "proj1" }),
    }]]);
  });

  test("keeps create and migrate as distinct guarded mutations", async () => {
    const requests = [];
    const fetchImpl = async (url, options) => {
      requests.push([url, options]);
      const operation = url.endsWith("/migrate") ? "migrate" : "create";
      return response({
        protocol: "swawkit.entry-instance-mutation/v2",
        operation,
        changed: true,
        entry: entry(),
      });
    };
    await createEntryInstance("proj1", fetchImpl);
    await migrateEntryInstance("proj1", fetchImpl);
    expect(requests).toEqual([
      ["/api/v2/entries", {
        method: "POST",
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json",
          "X-SwawKit-Control": "entry-instance-create",
        },
        body: JSON.stringify({ entryName: "proj1" }),
      }],
      ["/api/v2/entries/migrate", {
        method: "POST",
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json",
          "X-SwawKit-Control": "entry-instance-migrate",
        },
        body: JSON.stringify({ entryName: "proj1" }),
      }],
    ]);
  });

  test("surfaces HTTP diagnostics and rejects mismatched successful documents", async () => {
    await expect(readEntryInventory(async () => response({ error: "manager only" }, 404)))
      .rejects.toBeInstanceOf(EntryManagerClientError);
    await expect(createEntryInstance("proj1", async () => response({
      protocol: "swawkit.entry-instance-mutation/v2",
      operation: "migrate",
      changed: true,
      entry: entry(),
    }))).rejects.toThrow("different operation");
  });

  test("preserves the Runtime generation code for mutation callers", async () => {
    const error = await createEntryInstance("proj1", async () => response({
      code: "runtimeUpdateRequired",
      error: "server detail",
    }, 409)).catch((caught) => caught);

    expect(error).toBeInstanceOf(RuntimeGenerationError);
    expect(error.code).toBe("runtimeUpdateRequired");
    expect(error.message).toContain("Runtime 已更新");
  });
});
