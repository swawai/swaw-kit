import { commandRef } from "./command-identity.js";
import { commandFacetRoute } from "./resource-route.js";
import { runtimeGenerationMessage } from "./runtime-generation.js";
import { createViewBundle } from "./view-bundle-model.js";

export {
  RUNTIME_GENERATION_UNAVAILABLE_CODE,
  RUNTIME_UPDATE_REQUIRED_CODE,
} from "./runtime-generation.js";

export class FacetResolutionError extends Error {
  constructor(message, status = 0, code = null) {
    super(message);
    this.name = "FacetResolutionError";
    this.status = status;
    this.code = code;
  }
}

async function responseJson(response) {
  if (!response.ok) {
    let message = `Host returned HTTP ${response.status}`;
    let code = null;
    try {
      const body = await response.json();
      if (typeof body?.error === "string" && body.error) {
        message = body.error;
      }
      if (typeof body?.code === "string") {
        code = body.code;
      }
    } catch {
      // The HTTP status remains the useful failure signal.
    }
    const generationMessage = runtimeGenerationMessage(code);
    if (generationMessage) {
      message = generationMessage;
    } else {
      message = `Cannot resolve Resource Facet: ${message}`;
    }
    throw new FacetResolutionError(message, response.status, code);
  }
  return response.json();
}

export function createViewBundleLoader({
  onError,
  onLoading,
  onResolved,
  resolveViewBundle,
}) {
  let generation = 0;
  const versions = new Map();

  async function load(owner, facet) {
    const requestedGeneration = generation;
    const key = `${owner}#${facet}`;
    const version = (versions.get(key) ?? 0) + 1;
    versions.set(key, version);
    onLoading(owner, facet);
    try {
      const bundle = await resolveViewBundle(owner, facet);
      if (generation !== requestedGeneration || versions.get(key) !== version) {
        return null;
      }
      onResolved(bundle);
      return bundle;
    } catch (error) {
      if (generation !== requestedGeneration || versions.get(key) !== version) {
        return null;
      }
      onError(owner, facet, error);
      throw error;
    }
  }

  function reset() {
    generation += 1;
    versions.clear();
  }

  return { load, reset };
}

async function postRoute(url, route, fetchImpl) {
  const response = await fetchImpl(url, {
    body: JSON.stringify({ route }),
    cache: "no-store",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
    },
    method: "POST",
  });
  return responseJson(response);
}

export async function resolveDocumentFacet(
  resource,
  facet,
  { fetchImpl = fetch } = {},
) {
  if (!resource || !facet) {
    throw new Error("A Resource and one of its Facets are required.");
  }
  const dynamic = typeof resource.route === "string";
  if (facet.kind === "collection") {
    throw new Error("A document resolver cannot resolve a Collection Facet.");
  }
  const route = dynamic
    ? `${resource.route}/${facet.id}`
    : commandFacetRoute(commandRef(resource), facet.id);
  return postRoute("/api/v3/facet-resolutions", route, fetchImpl);
}

export async function resolveCollectionView(
  catalog,
  owner,
  facet,
  { fetchImpl = fetch } = {},
) {
  if (!owner || !facet || facet.kind !== "collection") {
    throw new Error("A Command Resource and one Collection Facet are required.");
  }
  if (typeof owner.route === "string") {
    throw new Error("Nested dynamic Resource collections are not supported.");
  }
  const route = commandFacetRoute(commandRef(owner), facet.id);
  const document = await postRoute("/api/v3/view-bundles", route, fetchImpl);
  return createViewBundle(document, catalog, owner, facet);
}
