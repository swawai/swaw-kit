import { describe, expect, test } from "bun:test";

import { createResourceList } from "./resource-list-model.js";
import { canonicalFacetRoute } from "./resource-route.js";

const runsKindSource = {
  resource: { hops: [{ facet: "system", selector: "runs" }] },
  facet: "all",
};

function collectionFacet(id = "all") {
  return {
    icon: "#",
    id,
    kind: "collection",
    label: "Runs",
    renderer: "collection",
    resolver: {
      acceptsTail: false,
      address: ".runs",
      arguments: ["--json"],
      confirmation: null,
      returns: "swawkit.resource-list/v2",
      type: "command",
    },
    resourceKind: { source: runsKindSource },
    summary: "Browse runs",
  };
}

function runKind() {
  return {
    kind: "run",
    source: runsKindSource,
    facets: [
      {
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
      },
      {
        id: "open",
        kind: "operation",
        renderer: "run",
        icon: ">",
        label: "Open",
        summary: "Open output",
        resolver: {
          type: "command",
          address: "artifact.open",
          arguments: [{ bind: "resource.selector" }],
          acceptsTail: false,
          confirmation: null,
          returns: null,
        },
      },
    ],
  };
}

function catalog() {
  const command = {
    address: ".runs",
    aliasOf: null,
    runnable: true,
    space: "system",
  };
  const resourceKind = runKind();
  return {
    resourceKindBySource: new Map([[
      canonicalFacetRoute(runsKindSource),
      { command, resourceKind },
    ]]),
  };
}

function source(ownerSelector, facet) {
  return {
    resource: { hops: [{ facet: "system", selector: ownerSelector }] },
    facet,
  };
}

function route(ownerSelector, facet, selector = "run-01") {
  return {
    hops: [
      { facet: "system", selector: ownerSelector },
      { facet, selector },
    ],
  };
}

function list(ownerSelector = "runs", facet = "all", facetIds = ["overview", "open"]) {
  return {
    protocol: "swawkit.resource-list/v2",
    source: source(ownerSelector, facet),
    resources: [{
      identity: {
        type: "instance",
        kind: runsKindSource,
        id: "run-01",
      },
      selector: "run-01",
      route: route(ownerSelector, facet),
      facetIds,
      label: "Run 01",
      summary: "successful run",
    }],
  };
}

const runsOwner = { type: "command", space: "system", address: ".runs" };

describe("Resource List v2 model", () => {
  test("binds trusted Resource Kind templates to one listed identity", () => {
    const result = createResourceList(list(), catalog(), runsOwner, collectionFacet());
    const resource = result.resources[0];

    expect(resource.route).toBe("$/system::runs/all::run-01");
    expect(resource.identity).toEqual({
      type: "instance",
      kind: runsKindSource,
      id: "run-01",
    });
    expect(resource.facets[1].resolver.arguments).toEqual(["run-01"]);
  });

  test("keeps route-local Facet grants separate for the same stable identity", () => {
    const global = createResourceList(list(), catalog(), runsOwner, collectionFacet());
    const commandOwner = { type: "command", space: "system", address: ".tool" };
    const local = createResourceList(
      list("tool", "runs", ["overview"]),
      catalog(),
      commandOwner,
      collectionFacet("runs"),
    );

    expect(global.resources[0].identityKey).toBe(local.resources[0].identityKey);
    expect(global.resources[0].route).not.toBe(local.resources[0].route);
    expect(global.resources[0].facets.map(({ id }) => id)).toEqual(["overview", "open"]);
    expect(local.resources[0].facets.map(({ id }) => id)).toEqual(["overview"]);
  });

  test("rejects source, identity, route, and grant mismatches", () => {
    expect(() => createResourceList(
      list(),
      catalog(),
      { type: "command", space: "system", address: ".check" },
      collectionFacet(),
    )).toThrow("source does not match");

    const wrongKind = list();
    wrongKind.resources[0].identity.kind = source("tool", "runs");
    expect(() => createResourceList(wrongKind, catalog(), runsOwner, collectionFacet()))
      .toThrow("does not belong");

    const wrongRoute = list();
    wrongRoute.resources[0].route = route("runs", "all", "other");
    expect(() => createResourceList(wrongRoute, catalog(), runsOwner, collectionFacet()))
      .toThrow("must record its unique Collection selection");

    const wrongGrant = list("runs", "all", ["missing"]);
    expect(() => createResourceList(wrongGrant, catalog(), runsOwner, collectionFacet()))
      .toThrow("unknown Facet");
  });

  test("rejects executable definitions and old collection data", () => {
    const extended = list();
    extended.resources[0].facets = [];
    expect(() => createResourceList(extended, catalog(), runsOwner, collectionFacet()))
      .toThrow("not part of Resource List v2");

    const old = list();
    old.protocol = "swawkit.subject-collection/v3";
    expect(() => createResourceList(old, catalog(), runsOwner, collectionFacet()))
      .toThrow("protocol must be swawkit.resource-list/v2");
  });
});
