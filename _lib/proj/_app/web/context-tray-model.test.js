import { describe, expect, test } from "bun:test";

import {
  contextAddInvocation,
  createPinnedContextRecord,
  parsePinnedContextRecord,
  pinnedContextRef,
} from "./context-tray-model.js";

function resource() {
  return {
    facets: [{
      id: "add",
      kind: "operation",
      renderer: "run",
      resolver: {
        acceptsTail: true,
        address: ".context/add",
        arguments: ["test"],
        confirmation: null,
        returns: null,
        type: "command",
      },
    }],
    identity: {
      id: "test",
      kind: {
        resource: { hops: [{ facet: "system", selector: "context" }] },
        facet: "contexts",
      },
      type: "instance",
    },
    collectionFacet: "contexts",
    ownerRef: { address: ".context", space: "system", type: "command" },
    route: "$/system::context/contexts::test",
    selector: "test",
  };
}

describe("Context tray model", () => {
  test("persists only typed identity and collection provenance", () => {
    const record = createPinnedContextRecord(resource());
    expect(parsePinnedContextRecord(JSON.stringify(record))).toEqual(record);
    expect(pinnedContextRef(record)).toBe("$/system::context/contexts::test");
    expect(JSON.stringify(record)).not.toContain("resolver");
  });

  test("rejects untrusted or extended session records", () => {
    const record = createPinnedContextRecord(resource());
    expect(() => parsePinnedContextRecord(JSON.stringify({
      ...record,
      resolver: { address: ".context/show" },
    }))).toThrow("invalid shape");
    expect(() => createPinnedContextRecord({
      ...resource(),
      identity: {
        ...resource().identity,
        kind: {
          resource: { hops: [{ facet: "system", selector: "runs" }] },
          facet: "all",
        },
      },
    })).toThrow("Context Resource");
  });

  test("maps the selected command through the declared add operation", () => {
    const invocation = contextAddInvocation(
      resource(),
      { address: ".dev/status", space: "system" },
      { commands: [] },
    );
    expect(invocation).toEqual({
      arguments: [".dev/status"],
      route: "$/system::context/contexts::test/add",
      state: "available",
    });
  });

  test("does not run for an existing command or an undeclared capability", () => {
    expect(contextAddInvocation(
      resource(),
      { address: ".dev/status", space: "system" },
      { commands: [{ address: ".dev/status", space: "system" }] },
    )).toEqual({ state: "present" });
    expect(contextAddInvocation(
      { ...resource(), facets: [] },
      { address: ".dev/status", space: "system" },
      { commands: [] },
    )).toBeNull();
  });
});
