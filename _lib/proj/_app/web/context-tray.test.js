import { describe, expect, test } from "bun:test";

import { createContextTrayView } from "./context-tray.js";

const STORAGE_KEY = "swawkit.web-pinned-context/v1";

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

function subject() {
  return {
    canonicalRef: "::context/tray-test",
    facets: [
      {
        id: "overview",
        kind: "projection",
        renderer: "overview",
        resolver: {
          acceptsTail: false,
          address: ".context.show",
          arguments: ["tray-test", "--json"],
          confirmation: null,
          returns: "swawkit.context/v1",
          type: "command",
        },
      },
      {
        id: "add",
        kind: "operation",
        renderer: "run",
        resolver: {
          acceptsTail: true,
          address: ".context.add",
          arguments: ["tray-test"],
          confirmation: null,
          returns: null,
          type: "command",
        },
      },
    ],
    label: "::tray-test",
    ref: { id: "tray-test", kind: "context", type: "instance" },
    summary: "0 个命令 · 0 条说明",
    via: {
      facet: "contexts",
      subject: { address: ".context", source: "kernel", type: "command" },
    },
  };
}

function document_(commands = []) {
  return {
    commands,
    id: "tray-test",
    notes: [],
    prompt: "",
    schema: "swawkit.context/v1",
  };
}

describe("Context tray", () => {
  test("pins, invokes the declared add Facet, refreshes, and unpins", async () => {
    const dom = elements();
    const session = storage();
    const instance = subject();
    let latest = document_();
    const calls = [];
    const pinned = [];
    const rendered = [];
    const tray = createContextTrayView(dom, {
      async executeOperation(address, arguments_) {
        calls.push({ address, arguments: arguments_ });
        latest = document_([{ address: ".dev.status", source: "kernel" }]);
      },
      async loadDocument() { return latest; },
      async loadSubject() { return instance; },
      onPinnedChange(reference) { pinned.push(reference); },
      renderFields(_fields, projection) { rendered.push(projection.commands); },
      storage: session,
    });

    await tray.pin(instance, latest);
    tray.selectCommand({ address: ".dev.status", source: "kernel" });
    expect(dom.contextTray.hidden).toBe(false);
    expect(dom.contextTrayAdd.disabled).toBe(false);
    expect(JSON.parse(session.getItem(STORAGE_KEY))).toEqual({
      schema: STORAGE_KEY,
      subject: { id: "tray-test", kind: "context", type: "instance" },
      via: {
        facet: "contexts",
        subject: { address: ".context", source: "kernel", type: "command" },
      },
    });

    expect(await tray.addCurrentCommand()).toBe(true);
    expect(calls).toEqual([{
      address: ".context.add",
      arguments: ["tray-test", ".dev.status"],
    }]);
    expect(rendered.at(-1)).toEqual([{ address: ".dev.status", source: "kernel" }]);
    expect(dom.contextTrayPresentLabel.hidden).toBe(false);
    expect(pinned.at(-1)).toBe("::context/tray-test");

    tray.unpin();
    expect(dom.contextTray.hidden).toBe(true);
    expect(session.getItem(STORAGE_KEY)).toBeNull();
    expect(pinned.at(-1)).toBeNull();
  });

  test("restores through current Subject and projection resolvers", async () => {
    const dom = elements();
    const session = storage();
    const instance = subject();
    session.setItem(STORAGE_KEY, JSON.stringify({
      schema: STORAGE_KEY,
      subject: { id: "tray-test", kind: "context", type: "instance" },
      via: {
        facet: "contexts",
        subject: { address: ".context", source: "kernel", type: "command" },
      },
    }));
    const loaded = [];
    const tray = createContextTrayView(dom, {
      async loadDocument(resolved) {
        loaded.push(resolved.canonicalRef);
        return document_();
      },
      async loadSubject(record) {
        loaded.push(record.via.facet);
        return instance;
      },
      renderFields() {},
      storage: session,
    });

    expect(await tray.restore()).toBe(true);
    expect(loaded).toEqual(["contexts", "::context/tray-test"]);
    expect(tray.pinnedRef()).toBe("::context/tray-test");
    expect(dom.contextTray.hidden).toBe(false);
  });

  test("does not apply an old operation result to a newly pinned Context", async () => {
    const dom = elements();
    const session = storage();
    const first = subject();
    const second = {
      ...subject(),
      canonicalRef: "::context/other",
      label: "::other",
      ref: { id: "other", kind: "context", type: "instance" },
    };
    let finish;
    const operation = new Promise((resolve) => { finish = resolve; });
    const tray = createContextTrayView(dom, {
      async executeOperation() { await operation; },
      async loadDocument(resolved) { return document_().id === resolved.ref.id
        ? document_()
        : { ...document_(), id: resolved.ref.id }; },
      async loadSubject() { return first; },
      renderFields() {},
      storage: session,
    });

    await tray.pin(first, document_());
    tray.selectCommand({ address: ".dev.status", source: "kernel" });
    const adding = tray.addCurrentCommand();
    await tray.pin(second, { ...document_(), id: "other" });
    finish();

    expect(await adding).toBe(true);
    expect(tray.pinnedRef()).toBe("::context/other");
    expect(dom.contextTrayFeedback.textContent).toBe("");
  });
});
