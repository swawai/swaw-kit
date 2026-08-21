import { describe, expect, test } from "bun:test";

import { createContextTrayView } from "./context-tray.js";

const STORAGE_KEY = "swawkit.web-pinned-context/v2";

function element() {
  return {
    dataset: {},
    disabled: false,
    hidden: false,
    listeners: new Map(),
    textContent: "",
    addEventListener(name, listener) { this.listeners.set(name, listener); },
  };
}

function elements() {
  return Object.fromEntries([
    "contextTray", "contextTrayAdd", "contextTrayAddLabel", "contextTrayCommand",
    "contextTrayCommandEmpty", "contextTrayCommands", "contextTrayFeedback",
    "contextTrayNotes", "contextTrayNotesEmpty", "contextTrayPresentLabel",
    "contextTrayPrompt", "contextTrayPromptEmpty", "contextTrayRef",
    "contextTraySummary", "contextTrayTitle", "contextTrayUnpin",
  ].map((name) => [name, element()]));
}

function storage() {
  const values = new Map();
  return {
    getItem(key) { return values.get(key) ?? null; },
    removeItem(key) { values.delete(key); },
    setItem(key, value) { values.set(key, value); },
  };
}

function resource(id = "tray-test") {
  return {
    facets: [
      {
        id: "overview",
        kind: "projection",
        renderer: "overview",
        resolver: {
          acceptsTail: false,
          address: ".context/show",
          arguments: [id, "--json"],
          confirmation: null,
          returns: "swawkit.context/v2",
          type: "command",
        },
      },
      {
        id: "add",
        kind: "operation",
        renderer: "run",
        resolver: {
          acceptsTail: true,
          address: ".context/add",
          arguments: [id],
          confirmation: null,
          returns: null,
          type: "command",
        },
      },
    ],
    collectionFacet: "contexts",
    identity: {
      id,
      kind: {
        resource: { hops: [{ facet: "system", selector: "context" }] },
        facet: "contexts",
      },
      type: "instance",
    },
    label: `::${id}`,
    ownerRef: { address: ".context", space: "system", type: "command" },
    route: `$/system::context/contexts::${id}`,
    selector: id,
    summary: "0 个命令 · 0 条说明",
  };
}

function document_(commands = []) {
  return {
    commands,
    id: "tray-test",
    notes: [],
    prompt: "",
    schema: "swawkit.context/v2",
  };
}

describe("Context tray", () => {
  test("pins, invokes the declared add Facet, refreshes, and unpins", async () => {
    const dom = elements();
    const session = storage();
    const instance = resource();
    let latest = document_();
    const calls = [];
    const pinned = [];
    const rendered = [];
    const tray = createContextTrayView(dom, {
      async executeOperation(route, arguments_) {
        calls.push({ route, arguments: arguments_ });
        latest = document_([{ address: ".dev/status", space: "system" }]);
      },
      async loadDocument() { return latest; },
      async loadResource() { return instance; },
      onPinnedChange(reference) { pinned.push(reference); },
      renderFields(_fields, projection) { rendered.push(projection.commands); },
      storage: session,
    });

    await tray.pin(instance, latest);
    tray.selectCommand({ address: ".dev/status", space: "system" });
    expect(dom.contextTray.hidden).toBe(false);
    expect(dom.contextTrayAdd.disabled).toBe(false);
    expect(JSON.parse(session.getItem(STORAGE_KEY))).toEqual({
      schema: STORAGE_KEY,
      identity: instance.identity,
      source: {
        facet: "contexts",
        owner: { address: ".context", space: "system", type: "command" },
        selector: "tray-test",
      },
    });

    expect(await tray.addCurrentCommand()).toBe(true);
    expect(calls).toEqual([{
      route: "$/system::context/contexts::tray-test/add",
      arguments: [".dev/status"],
    }]);
    expect(rendered.at(-1)).toEqual([{ address: ".dev/status", space: "system" }]);
    expect(dom.contextTrayPresentLabel.hidden).toBe(false);
    expect(pinned.at(-1)).toBe("$/system::context/contexts::tray-test");

    tray.unpin();
    expect(dom.contextTray.hidden).toBe(true);
    expect(session.getItem(STORAGE_KEY)).toBeNull();
    expect(pinned.at(-1)).toBeNull();
  });

  test("restores through current Resource and projection resolvers", async () => {
    const dom = elements();
    const session = storage();
    const instance = resource();
    session.setItem(STORAGE_KEY, JSON.stringify({
      schema: STORAGE_KEY,
      identity: instance.identity,
      source: {
        facet: "contexts",
        owner: { address: ".context", space: "system", type: "command" },
        selector: "tray-test",
      },
    }));
    const loaded = [];
    const tray = createContextTrayView(dom, {
      async loadDocument(resolved) {
        loaded.push(resolved.route);
        return document_();
      },
      async loadResource(record) {
        loaded.push(record.source.facet);
        return instance;
      },
      renderFields() {},
      storage: session,
    });

    expect(await tray.restore()).toBe(true);
    expect(loaded).toEqual(["contexts", "$/system::context/contexts::tray-test"]);
    expect(tray.pinnedRef()).toBe("$/system::context/contexts::tray-test");
    expect(dom.contextTray.hidden).toBe(false);
  });

  test("does not apply an old operation result to a newly pinned Context", async () => {
    const dom = elements();
    const session = storage();
    const first = resource();
    const second = resource("other");
    let finish;
    const operation = new Promise((resolve) => { finish = resolve; });
    const tray = createContextTrayView(dom, {
      async executeOperation() { await operation; },
      async loadDocument(resolved) { return document_().id === resolved.identity.id
        ? document_()
        : { ...document_(), id: resolved.identity.id }; },
      async loadResource() { return first; },
      renderFields() {},
      storage: session,
    });

    await tray.pin(first, document_());
    tray.selectCommand({ address: ".dev/status", space: "system" });
    const adding = tray.addCurrentCommand();
    await tray.pin(second, { ...document_(), id: "other" });
    finish();

    expect(await adding).toBe(true);
    expect(tray.pinnedRef()).toBe("$/system::context/contexts::other");
    expect(dom.contextTrayFeedback.textContent).toBe("");
  });

  test("refreshes Runtime status when its operation reaches a stale Host", async () => {
    const dom = elements();
    const instance = resource();
    let notifications = 0;
    const tray = createContextTrayView(dom, {
      async executeOperation() {
        const error = new Error("Runtime 已更新");
        error.code = "runtimeUpdateRequired";
        throw error;
      },
      async loadDocument() { return document_(); },
      async loadResource() { return instance; },
      onRuntimeUpdateRequired() { notifications += 1; },
      renderFields() {},
      storage: storage(),
    });
    await tray.pin(instance, document_());
    tray.selectCommand({ address: ".dev/status", space: "system" });

    expect(await tray.addCurrentCommand()).toBe(false);
    expect(notifications).toBe(1);
    expect(dom.contextTrayFeedback.textContent).toBe("Runtime 已更新");
  });
});
