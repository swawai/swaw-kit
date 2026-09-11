import { describe, expect, test } from "bun:test";
import { createContextProjection } from "./context-projection-model.js";

describe("Context projection model", () => {
  test("validates the selected Context document", () => {
    expect(createContextProjection({
      schema: "swawkit.context/v2",
      id: "release-check",
      commands: [{ space: "system", address: ".dev/status" }],
      notes: ["Inspect"],
      prompt: "Build",
    }, "release-check").commands[0].address).toBe(".dev/status");
  });
});
