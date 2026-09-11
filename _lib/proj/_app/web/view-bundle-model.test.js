import { describe, expect, test } from "bun:test";

import { createViewBundle } from "./view-bundle-model.js";
import { canonicalFacetRoute } from "./resource-route.js";

const runsKindSource = {
  resource: { hops: [{ facet: "system", selector: "runs" }] },
  facet: "all",
};

function dynamicFacet() {
  return {
    id: "runs",
    kind: "collection",
    label: "Runs",
    renderer: "collection",
    resolver: {
      address: ".runs",
      arguments: ["--json"],
      returns: "swawkit.resource-list/v2",
      type: "command",
    },
    resourceKind: { source: runsKindSource },
  };
}

function runKind() {
  return {
    kind: "run",
    source: runsKindSource,
    facets: [{
      id: "overview",
      kind: "projection",
      renderer: "overview",
      icon: "i",
      label: "Overview",
      summary: "Inspect run",
      resolver: {
        type: "command",
        address: ".runs",
        arguments: [{ bind: "resource.selector" }],
        acceptsTail: false,
        confirmation: null,
        returns: "fixture.run/v1",
      },
    }],
  };
}

function viewBundle(target, resourceList, width = "normal") {
  return {
    protocol: "swawkit.view-bundle/web/v1",
    target,
    view: {
      width,
      body: { component: "resource-list", source: "facet-result" },
    },
    resources: { "facet-result": resourceList },
  };
}

describe("Web View Bundle model", () => {
  test("binds one dynamic Resource List and its layout to the same target", () => {
    const target = {
      resource: { hops: [{ facet: "system", selector: "tool" }] },
      facet: "runs",
    };
    const owner = { address: ".tool", space: "system" };
    const resourceKind = runKind();
    const catalog = {
      commandByResourceRoute: new Map(),
      resourceKindBySource: new Map([[
        canonicalFacetRoute(runsKindSource),
        { command: { address: ".runs" }, resourceKind },
      ]]),
    };
    const resourceList = {
      protocol: "swawkit.resource-list/v2",
      source: target,
      resources: [{
        identity: { type: "instance", kind: runsKindSource, id: "run-01" },
        selector: "run-01",
        route: { hops: [
          { facet: "system", selector: "tool" },
          { facet: "runs", selector: "run-01" },
        ] },
        facetIds: ["overview"],
        label: "Run 01",
        summary: "complete",
      }],
    };

    const bundle = createViewBundle(
      viewBundle(target, resourceList, "wide"),
      catalog,
      owner,
      dynamicFacet(),
    );
    expect(bundle.target).toBe("$/system::tool/runs");
    expect(bundle.view.width).toBe("wide");
    expect(bundle.resourceList.resources[0].route).toBe("$/system::tool/runs::run-01");
  });

  test("maps a static listing back to its exact Catalog Command", () => {
    const target = {
      resource: { hops: [{ facet: "system", selector: "dev" }] },
      facet: "subcommands",
    };
    const route = {
      hops: [
        { facet: "system", selector: "dev" },
        { facet: "subcommands", selector: "bun" },
      ],
    };
    const command = {
      address: ".dev/bun",
      facets: [{ id: "execute" }],
      parent: ".dev",
      space: "system",
    };
    const catalog = {
      commandByResourceRoute: new Map([["$/system::dev/subcommands::bun", command]]),
      resourceKindBySource: new Map(),
    };
    const facet = {
      id: "subcommands",
      kind: "collection",
      label: "Subcommands",
      renderer: "collection",
      resolver: { relation: "subcommands", type: "catalog" },
      resourceKind: null,
    };
    const resourceList = {
      protocol: "swawkit.resource-list/v2",
      source: target,
      resources: [{
        identity: { type: "static", route },
        selector: "bun",
        route,
        facetIds: ["execute"],
        label: "bun",
        summary: "JavaScript runtime",
      }],
    };

    const bundle = createViewBundle(
      viewBundle(target, resourceList),
      catalog,
      { address: ".dev", space: "system" },
      facet,
    );
    expect(bundle.resourceList.resources[0].command).toBe(command);
  });

  test("rejects a layout or Resource List from another target", () => {
    const target = {
      resource: { hops: [{ facet: "system", selector: "tool" }] },
      facet: "runs",
    };
    const invalid = viewBundle(target, {
      protocol: "swawkit.resource-list/v2",
      source: target,
      resources: [],
    });
    invalid.view.body.source = "remote";
    expect(() => createViewBundle(
      invalid,
      { commandByResourceRoute: new Map(), resourceKindBySource: new Map() },
      { address: ".tool", space: "system" },
      dynamicFacet(),
    )).toThrow("resolved Facet Resource List");
  });
});
