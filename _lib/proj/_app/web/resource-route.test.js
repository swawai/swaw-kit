import { describe, expect, test } from "bun:test";

import { commandFacetRoute, commandResourceRoute } from "./resource-route.js";

describe("Resource Route", () => {
  test("maps static Command identity to explicit subcommands traversal", () => {
    expect(commandResourceRoute({
      address: ".dev/bun/mode",
      space: "system",
      type: "command",
    })).toBe("$/system::dev/subcommands::bun/subcommands::mode");
    expect(commandResourceRoute({
      address: "swaw/context/show",
      namespace: "swaw",
      space: "module",
      type: "command",
    })).toBe("$/modules::swaw/subcommands::context/subcommands::show");
  });

  test("appends a Facet to one static Command Resource", () => {
    expect(commandFacetRoute(
      { address: ".context", space: "system", type: "command" },
      "contexts",
    )).toBe("$/system::context/contexts");
  });
});
