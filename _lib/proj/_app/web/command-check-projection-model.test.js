import { describe, expect, test } from "bun:test";

import {
  COMMAND_CHECK_PROTOCOL,
  createCommandCheckProjection,
} from "./command-check-projection-model.js";

function document(overrides = {}) {
  return {
    protocol: COMMAND_CHECK_PROTOCOL,
    command: {
      address: ".tool",
      space: "system",
      namespace: null,
      runnable: true,
      adapter: "pwsh",
      diagnostic: null,
    },
    dependencies: [],
    ready: true,
    ...overrides,
  };
}

function dependency(overrides = {}) {
  return {
    provider: ".provider",
    export: "fixture",
    ready: true,
    status: "ready",
    message: null,
    checker: null,
    dependencies: [],
    ...overrides,
  };
}

describe("Command check projection model", () => {
  test("normalizes the exact command check document", () => {
    const value = document({ dependencies: [dependency()] });
    expect(createCommandCheckProjection(value, {
      address: ".tool",
      space: "system",
    })).toEqual(value);
  });

  test("rejects a document belonging to another command namespace", () => {
    expect(() => createCommandCheckProjection(document(), {
      address: "project/tool",
      namespace: "project",
      space: "module",
    })).toThrow("command identity");
  });

  test("rejects readiness inconsistent with command dependencies", () => {
    expect(() => createCommandCheckProjection(document({
      dependencies: [dependency({ ready: false, status: "not-ready" })],
    }), {
      address: ".tool",
      space: "system",
    })).toThrow("ready");
  });

  test("normalizes a structured provider checker without executing it", () => {
    const result = createCommandCheckProjection(document({
      dependencies: [dependency({
        checker: {
          address: ".provider/check",
          arguments: ["fixture"],
          namespace: null,
          space: "system",
        },
      })],
    }), { address: ".tool", space: "system" });

    expect(result.dependencies[0].checker).toEqual({
      address: ".provider/check",
      arguments: ["fixture"],
      namespace: null,
      path: ["provider", "check"],
      space: "system",
    });
  });

  test("rejects internally inconsistent dependency readiness", () => {
    const commandResource = { address: ".tool", space: "system" };
    expect(() => createCommandCheckProjection(document({
      dependencies: [dependency({ status: "state-missing" })],
    }), commandResource)).toThrow("status");
    expect(() => createCommandCheckProjection(document({
      dependencies: [dependency({
        dependencies: [dependency({ ready: false, status: "state-missing" })],
      })],
    }), commandResource)).toThrow("子依赖");
  });

  test("preserves the export-not-declared dependency status", () => {
    const result = createCommandCheckProjection(document({
      dependencies: [dependency({ ready: false, status: "export-not-declared" })],
      ready: false,
    }), { address: ".tool", space: "system" });

    expect(result.dependencies[0].status).toBe("export-not-declared");
  });

  test("rejects the old protocol and removed publication fields", () => {
    expect(() => createCommandCheckProjection(document({
      protocol: "swawkit.command-check/v2",
    }), {
      address: ".tool",
      space: "system",
    })).toThrow(COMMAND_CHECK_PROTOCOL);
    expect(() => createCommandCheckProjection({
      ...document(),
      publications: [],
    }, {
      address: ".tool",
      space: "system",
    })).toThrow("字段必须精确");
    expect(() => createCommandCheckProjection(document({
      dependencies: [dependency({ publication: null })],
    }), {
      address: ".tool",
      space: "system",
    })).toThrow("字段必须精确");
    expect(() => createCommandCheckProjection(document({
      dependencies: [dependency({ contract: "removed/v1" })],
    }), {
      address: ".tool",
      space: "system",
    })).toThrow("字段必须精确");
  });
});
