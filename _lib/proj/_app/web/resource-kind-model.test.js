import { describe, expect, test } from "bun:test";

import {
  instantiateResourceFacets,
  normalizeResourceKinds,
} from "./resource-kind-model.js";

const invalid = (message) => new Error(message);

function kinds(argumentsTemplate = [{ bind: "resource.selector" }]) {
  return [{
    kind: "context",
    source: {
      resource: { hops: [{ facet: "system", selector: "context" }] },
      facet: "contexts",
    },
    facets: [{
      id: "overview",
      kind: "projection",
      renderer: "overview",
      icon: "i",
      label: "Overview",
      summary: "Inspect Context",
      resolver: {
        type: "command",
        address: ".context/show",
        arguments: argumentsTemplate,
        returns: "swawkit.context/v2",
      },
    }],
  }];
}

describe("Resource Kind template model", () => {
  test("keeps resource.selector typed until one trusted instance is selected", () => {
    const [resourceKind] = normalizeResourceKinds(kinds(), "resourceKinds", invalid);
    expect(resourceKind.facets[0].resolver.arguments).toEqual([{ bind: "resource.selector" }]);
    expect(instantiateResourceFacets(
      resourceKind,
      ["overview"],
      "release-check",
      invalid,
    )[0].resolver.arguments).toEqual(["release-check"]);
  });

  test("rejects string interpolation and bindings from another Resource scope", () => {
    expect(() => normalizeResourceKinds(
      kinds([{ bind: "commandAddress" }]),
      "resourceKinds",
      invalid,
    )).toThrow("must bind resource.selector");
    expect(() => normalizeResourceKinds(
      kinds([{ bind: "resource.selector", fallback: "unsafe" }]),
      "resourceKinds",
      invalid,
    )).toThrow("must bind resource.selector");
  });

  test("rejects an undeclared stateful Facet subset", () => {
    const [resourceKind] = normalizeResourceKinds(kinds(), "resourceKinds", invalid);
    expect(() => instantiateResourceFacets(
      resourceKind,
      ["delete"],
      "release-check",
      invalid,
    )).toThrow("unknown Facet");
  });
});
