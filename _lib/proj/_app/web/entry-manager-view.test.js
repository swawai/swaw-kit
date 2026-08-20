import { describe, expect, test } from "bun:test";

import { createEntryManagerView } from "./entry-manager-view.js";

function node() {
  return {
    children: [],
    dataset: {},
    disabled: false,
    hidden: false,
    textContent: "",
    value: "",
    listeners: {},
    addEventListener(name, listener) {
      this.listeners[name] = listener;
    },
    append(...children) {
      this.children.push(...children);
    },
    replaceChildren(...children) {
      this.children = children;
    },
    setAttribute(name, value) {
      this[name] = value;
    },
  };
}

function elements() {
  return {
    workspace: node(),
    catalogCanvas: node(),
    entryManagerNavigation: node(),
    entryManagerTab: node(),
    entryConsoleTab: node(),
    entryManagerPanel: node(),
    entryManagerForm: node(),
    entryManagerInput: node(),
    entryManagerHome: node(),
    entryManagerEntryFile: node(),
    entryManagerDataRoot: node(),
    entryManagerState: node(),
    entryManagerIssues: node(),
    entryManagerFeedback: node(),
    entryManagerCreate: node(),
    entryManagerMigrate: node(),
    entryManagerRefresh: node(),
    entryManagerInventory: node(),
    entryManagerInventoryEmpty: node(),
  };
}

function entry(status, overrides = {}) {
  const ready = status === "ready";
  return {
    entryName: "proj1",
    entryFile: "D:\\kit\\proj1.exe",
    dataRoot: "D:\\kit\\data\\proj.proj1",
    status,
    entryId: ready ? "a".repeat(64) : null,
    releaseId: ready ? "b".repeat(64) : null,
    issues: [],
    ...overrides,
  };
}

function response(document, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => document,
  };
}

const documentImpl = { createElement: node };

describe("Entry manager view", () => {
  test("ordinary Entries never request or reveal the manager API", async () => {
    const ui = elements();
    let requests = 0;
    const view = createEntryManagerView(ui, {
      documentImpl,
      fetchImpl: async () => {
        requests += 1;
        throw new Error("must not request");
      },
    });
    expect(await view.activate("proj1")).toBe(false);
    expect(requests).toBe(0);
    expect(ui.entryManagerNavigation.hidden).toBe(true);
    expect(ui.entryManagerPanel.hidden).toBe(true);
    expect(ui.catalogCanvas.hidden).toBe(false);
  });

  test("manager activation defaults to the panel and projects paths immediately", async () => {
    const ui = elements();
    const view = createEntryManagerView(ui, {
      documentImpl,
      fetchImpl: async (url) => response(url.endsWith("/inspect")
        ? {
          protocol: "swawkit.entry-instance-state/v1",
          entry: entry("available"),
        }
        : {
          protocol: "swawkit.entry-inventory/v1",
          swawkitHome: "D:\\kit",
          entries: [],
        }),
    });
    expect(await view.activate("swawkit")).toBe(true);
    expect(ui.entryManagerNavigation.hidden).toBe(false);
    expect(ui.entryManagerPanel.hidden).toBe(false);
    expect(ui.catalogCanvas.hidden).toBe(true);
    expect(ui.entryManagerHome.textContent).toBe("D:\\kit");

    ui.entryManagerInput.value = "proj1";
    await view.inspect();
    expect(ui.entryManagerEntryFile.textContent).toBe("D:\\kit\\proj1.exe");
    expect(ui.entryManagerDataRoot.textContent).toBe("D:\\kit\\data\\proj.proj1");

    view.showConsole();
    expect(ui.entryManagerPanel.hidden).toBe(true);
    expect(ui.catalogCanvas.hidden).toBe(false);
    view.showManager();
    expect(ui.entryManagerPanel.hidden).toBe(false);
  });

  test("enables only the state-specific mutation and refreshes after create", async () => {
    const ui = elements();
    const requests = [];
    let created = false;
    const fetchImpl = async (url, options = {}) => {
      requests.push([url, options]);
      if (url === "/api/v2/entries" && options.method === "POST") {
        created = true;
        return response({
          protocol: "swawkit.entry-instance-mutation/v1",
          operation: "create",
          changed: true,
          entry: entry("ready"),
        });
      }
      if (url === "/api/v2/entries/inspect") {
        return response({
          protocol: "swawkit.entry-instance-state/v1",
          entry: entry(created ? "ready" : "available"),
        });
      }
      return response({
        protocol: "swawkit.entry-inventory/v1",
        swawkitHome: "D:\\kit",
        entries: created ? [entry("ready")] : [],
      });
    };
    const view = createEntryManagerView(ui, { documentImpl, fetchImpl });
    await view.activate("swawkit");
    ui.entryManagerInput.value = "proj1";
    await view.inspect();
    expect(ui.entryManagerCreate.disabled).toBe(false);
    expect(ui.entryManagerMigrate.disabled).toBe(true);

    const mutation = await view.create();
    expect(mutation.operation).toBe("create");
    expect(ui.entryManagerState.dataset.status).toBe("ready");
    expect(ui.entryManagerCreate.disabled).toBe(true);
    expect(ui.entryManagerInventory.children).toHaveLength(1);
    expect(requests.some(([url, options]) => (
      url === "/api/v2/entries"
      && options.headers?.["X-SwawKit-Control"] === "entry-instance-create"
    ))).toBe(true);
  });

  test("keeps legacy migration explicit and renders server issues", async () => {
    const ui = elements();
    const legacy = entry("legacyMigrationRequired", { issues: ["legacy identity record"] });
    const ready = entry("ready");
    const fetchImpl = async (url) => {
      if (url === "/api/v2/entries/inspect") {
        return response({ protocol: "swawkit.entry-instance-state/v1", entry: legacy });
      }
      if (url === "/api/v2/entries/migrate") {
        return response({
          protocol: "swawkit.entry-instance-mutation/v1",
          operation: "migrate",
          changed: true,
          entry: ready,
        });
      }
      return response({
        protocol: "swawkit.entry-inventory/v1",
        swawkitHome: "D:\\kit",
        entries: [],
      });
    };
    const view = createEntryManagerView(ui, { documentImpl, fetchImpl });
    await view.activate("swawkit");
    ui.entryManagerInput.value = "proj1";
    await view.inspect();
    expect(ui.entryManagerCreate.disabled).toBe(true);
    expect(ui.entryManagerMigrate.disabled).toBe(false);
    expect(ui.entryManagerIssues.children[0].textContent).toBe("legacy identity record");
    await view.migrate();
    expect(ui.entryManagerState.dataset.status).toBe("ready");
  });
});
