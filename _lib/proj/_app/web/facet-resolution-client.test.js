import { describe, expect, test } from "bun:test";

import {
  createViewBundleLoader,
  FacetResolutionError,
  RUNTIME_UPDATE_REQUIRED_CODE,
  resolveCollectionView,
  resolveDocumentFacet,
} from "./facet-resolution-client.js";

function response(document) {
  return { json: async () => document, ok: true, status: 200 };
}

describe("Facet resolution client", () => {
  test("posts one canonical Command Facet Route", async () => {
    let request = null;
    const command = { address: ".check", space: "system" };
    const facet = {
      id: "status",
      kind: "projection",
      resolver: { returns: "swawkit.command-check/v3", type: "command" },
    };
    const document = { protocol: "swawkit.command-check/v3" };
    const result = await resolveDocumentFacet(command, facet, {
      fetchImpl: async (url, options) => {
        request = { options, url };
        return response(document);
      },
    });

    expect(result).toBe(document);
    expect(request.url).toBe("/api/v3/facet-resolutions");
    expect(request.options.method).toBe("POST");
    expect(JSON.parse(request.options.body)).toEqual({ route: "$/system::check/status" });
  });

  test("encodes Collection provenance in a dynamic Resource Facet Route", async () => {
    let body = null;
    const resource = { route: "$/system::tool/runs::run-01" };
    const facet = {
      id: "overview",
      kind: "projection",
      resolver: { returns: "swawkit.run/v1", type: "command" },
    };
    await resolveDocumentFacet(resource, facet, {
      fetchImpl: async (_url, options) => {
        body = JSON.parse(options.body);
        return response({ protocol: "swawkit.run/v1" });
      },
    });
    expect(body).toEqual({ route: "$/system::tool/runs::run-01/overview" });
  });

  test("rejects instance-owned collections instead of exposing half-usable children", async () => {
    const resource = { route: "$/system::runs/all::run-01" };
    await expect(resolveCollectionView({}, resource, {
      id: "artifacts",
      kind: "collection",
    }, {
      fetchImpl: async () => { throw new Error("must not fetch"); },
    })).rejects.toThrow("Nested dynamic Resource collections");
  });

  test("preserves the Runtime generation error for the application boundary", async () => {
    const command = { address: ".check", space: "system" };
    const facet = {
      id: "status",
      kind: "projection",
      resolver: { returns: "swawkit.command-check/v3", type: "command" },
    };
    const error = await resolveDocumentFacet(command, facet, {
      fetchImpl: async () => ({
        json: async () => ({
          code: RUNTIME_UPDATE_REQUIRED_CODE,
          error: "server detail",
        }),
        ok: false,
        status: 409,
      }),
    }).catch((caught) => caught);

    expect(error).toBeInstanceOf(FacetResolutionError);
    expect(error.status).toBe(409);
    expect(error.code).toBe(RUNTIME_UPDATE_REQUIRED_CODE);
    expect(error.message).toContain("Runtime 已更新");
  });

  test("does not let stale View Bundle responses or errors replace the latest state", async () => {
    const pending = [];
    const resolved = [];
    const errors = [];
    const loader = createViewBundleLoader({
      onError(_owner, _facet, error) { errors.push(error.message); },
      onLoading() {},
      onResolved(list) { resolved.push(list.value); },
      resolveViewBundle() {
        return new Promise((resolve, reject) => pending.push({ reject, resolve }));
      },
    });

    const staleResponse = loader.load(".runs", "runs");
    const currentResponse = loader.load(".runs", "runs");
    pending[1].resolve({ value: "current" });
    expect(await currentResponse).toEqual({ value: "current" });
    pending[0].resolve({ value: "stale" });
    expect(await staleResponse).toBeNull();

    const staleError = loader.load(".runs", "runs");
    const newestResponse = loader.load(".runs", "runs");
    pending[3].resolve({ value: "newest" });
    await newestResponse;
    pending[2].reject(new Error("stale failure"));
    expect(await staleError).toBeNull();

    expect(resolved).toEqual(["current", "newest"]);
    expect(errors).toEqual([]);
  });

  test("drops a View Bundle resolved for an obsolete Catalog generation", async () => {
    let settle;
    const resolved = [];
    const loader = createViewBundleLoader({
      onError() {},
      onLoading() {},
      onResolved(bundle) { resolved.push(bundle); },
      resolveViewBundle() {
        return new Promise((resolve) => { settle = resolve; });
      },
    });

    const obsolete = loader.load(".dev", "subcommands");
    loader.reset();
    settle({ value: "old Catalog" });

    expect(await obsolete).toBeNull();
    expect(resolved).toEqual([]);
  });
});
