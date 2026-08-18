import { describe, expect, test } from "bun:test";

import {
  contextAddInvocation,
  createPinnedContextRecord,
  parsePinnedContextRecord,
  pinnedContextRef,
} from "./context-tray-model.js";

function subject() {
  return {
    facets: [{
      id: "add",
      kind: "operation",
      renderer: "run",
      resolver: {
        acceptsTail: true,
        address: "swaw/context/add",
        arguments: ["test"],
        confirmation: null,
        returns: null,
        type: "command",
      },
    }],
    ref: { id: "test", kind: "context", type: "instance" },
    via: {
      facet: "contexts",
      subject: {
        address: "swaw/context",
        namespace: "swaw",
        space: "module",
        type: "command",
      },
    },
  };
}

describe("Context tray model", () => {
  test("persists only typed identity and collection provenance", () => {
    const record = createPinnedContextRecord(subject());
    expect(parsePinnedContextRecord(JSON.stringify(record))).toEqual(record);
    expect(pinnedContextRef(record)).toBe("::context/test");
    expect(JSON.stringify(record)).not.toContain("resolver");
  });

  test("rejects untrusted or extended session records", () => {
    const record = createPinnedContextRecord(subject());
    expect(() => parsePinnedContextRecord(JSON.stringify({
      ...record,
      resolver: { address: "swaw/context/show" },
    }))).toThrow("invalid shape");
    expect(() => createPinnedContextRecord({
      ...subject(),
      ref: { id: "test", kind: "run", type: "instance" },
    })).toThrow("Context Subject");
  });

  test("maps the selected command through the declared add operation", () => {
    const invocation = contextAddInvocation(
      subject(),
      { address: ".dev/status", space: "system" },
      { commands: [] },
    );
    expect(invocation).toEqual({
      address: "swaw/context/add",
      arguments: ["test", ".dev/status"],
      state: "available",
    });
  });

  test("does not run for an existing command or an undeclared capability", () => {
    expect(contextAddInvocation(
      subject(),
      { address: ".dev/status", space: "system" },
      { commands: [{ address: ".dev/status", space: "system" }] },
    )).toEqual({ state: "present" });
    expect(contextAddInvocation(
      { ...subject(), facets: [] },
      { address: ".dev/status", space: "system" },
      { commands: [] },
    )).toBeNull();
  });
});
