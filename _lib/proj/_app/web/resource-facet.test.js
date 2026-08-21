import { describe, expect, test } from "bun:test";

import {
  createResourceFacetView,
  defaultCommandFacet,
  defaultResourceFacet,
  resourceFacetItems,
  resourceFacets,
} from "./resource-facet.js";

function facet(id, renderer = id) {
  return {
    icon: id.slice(0, 1),
    id,
    kind: renderer === "overview" ? "projection" : "operation",
    label: id,
    renderer,
    resolver: {
        acceptsTail: false,
        address: ".fixture",
        arguments: [],
        confirmation: null,
        returns: renderer === "overview" ? "fixture.document/v1" : null,
        type: "command",
      },
    summary: `${id} summary`,
  };
}

function collection(id, resolver) {
  return {
    icon: id.slice(0, 1),
    id,
    kind: "collection",
    label: id,
    renderer: "collection",
    resolver,
    summary: `${id} summary`,
  };
}

describe("Resource Facets", () => {
  test("uses only Facets resolved by the Catalog", () => {
    const facets = [
      facet("overview"),
      facet("help"),
      facet("run"),
    ];
    expect(resourceFacets({ facets })).toBe(facets);
    expect(resourceFacets({ facets: [] })).toEqual([]);
    expect(resourceFacets(null)).toEqual([]);
  });

  test("uses structural and command collection resolvers without adapters", () => {
    const resource = {
      facets: [
        collection("subcommands", { relation: "subcommands", type: "catalog" }),
        collection("runs", {
          acceptsTail: false,
          address: ".runs",
          arguments: [],
          confirmation: null,
          returns: "swawkit.resource-list/v2",
          type: "command",
        }),
        facet("overview"),
      ],
      address: "project/build",
    };
    expect(resourceFacetItems(resource).map(({ name }) => name)).toEqual([
      "subcommands",
      "runs",
      "overview",
    ]);
    expect(defaultResourceFacet(resource)).toBe("subcommands");
    expect(defaultResourceFacet(null)).toBeNull();
  });

  test("opens the stateful Runtime root on overview", () => {
    const resource = {
      facets: [facet("overview")],
      address: ".runtime",
      handler: "runtime.status",
    };
    expect(defaultResourceFacet(resource)).toBe("overview");
    expect(defaultCommandFacet(resource)).toBeNull();
  });

  test("keeps ordinary Command details outside Facet selection", () => {
    const resource = {
      facets: [facet("help"), collection("runs", {
        acceptsTail: false,
        address: ".runs",
        arguments: [],
        confirmation: null,
        returns: "swawkit.resource-list/v2",
        type: "command",
      })],
      address: ".fixture",
    };
    expect(defaultCommandFacet(resource)).toBeNull();

    const pane = () => ({ hidden: false });
    const elements = {
      commandWorkspace: pane(),
      entryConfigDetail: pane(),
      commandDetail: pane(),
      commandHelpPane: pane(),
      commandRunPane: pane(),
    };
    const view = createResourceFacetView(elements, {
      defaultFacet: defaultCommandFacet,
      fallbackRenderer: "overview",
    });
    expect(view.select(resource)).toEqual({
      defaultFacet: null,
      facet: null,
      selectedFacet: null,
    });
    expect(elements.commandWorkspace.hidden).toBeFalse();
    expect(elements.commandDetail.hidden).toBeFalse();
  });

  test("renders a custom Facet through its declared renderer", () => {
    const pane = () => ({ hidden: false });
    const elements = {
      commandWorkspace: pane(),
      entryConfigDetail: pane(),
      commandDetail: pane(),
      commandHelpPane: pane(),
      commandRunPane: pane(),
    };
    const view = createResourceFacetView(elements);
    const command = {
      facets: [facet("overview"), facet("validate", "run")],
      address: ".fixture",
    };

    expect(view.select(command, { facet: "validate" })).toEqual({
      defaultFacet: "overview",
      facet: expect.objectContaining({ name: "validate", renderer: "run" }),
      selectedFacet: "validate",
    });
    expect(elements.commandRunPane.hidden).toBeFalse();
    expect(elements.commandWorkspace.hidden).toBeFalse();
    expect(elements.commandDetail.hidden).toBeTrue();
  });

  test("routes overridden conventional ids only by their declared renderer", () => {
    for (const id of ["help", "runs"]) {
      const pane = () => ({ hidden: false });
      const elements = {
        commandWorkspace: pane(),
        entryConfigDetail: pane(),
        commandDetail: pane(),
        commandHelpPane: pane(),
        commandRunPane: pane(),
      };
      const view = createResourceFacetView(elements);
      view.select({
        address: ".fixture",
        facets: [facet("overview"), facet(id, "run")],
      }, { facet: id });

      expect(elements.commandRunPane.hidden).toBeFalse();
      expect(elements.commandHelpPane.hidden).toBeTrue();
    }
  });

  test("selects a collection without opening a projection pane", () => {
    const pane = () => ({ hidden: false });
    const elements = {
      commandWorkspace: pane(),
      entryConfigDetail: pane(),
      commandDetail: pane(),
      commandHelpPane: pane(),
      commandRunPane: pane(),
    };
    const view = createResourceFacetView(elements);
    const command = {
      facets: [
        collection("runs", {
          acceptsTail: false,
          address: ".runs",
          arguments: [],
          confirmation: null,
          returns: "swawkit.resource-list/v2",
          type: "command",
        }),
        facet("overview"),
      ],
      address: ".fixture",
    };

    expect(view.select(command, { facet: "runs" })).toEqual({
      defaultFacet: "runs",
      facet: expect.objectContaining({ kind: "collection", name: "runs" }),
      selectedFacet: "runs",
    });
    expect(elements.commandWorkspace.hidden).toBeTrue();
    expect(view.items(command).find(({ name }) => name === "runs")?.selected).toBeTrue();
  });
});
