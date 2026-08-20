import { createSubjectCollection } from "./subject-collection-model.js";
import { commandRef } from "./command-identity.js";
import { runtimeGenerationMessage } from "./runtime-generation.js";

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
      message = `Cannot resolve Subject Facet: ${message}`;
    }
    throw new FacetResolutionError(message, response.status, code);
  }
  return response.json();
}

export function createCollectionResolutionLoader({
  onError,
  onLoading,
  onResolved,
  resolveCollection,
}) {
  const versions = new Map();

  async function load(owner, facet) {
    const key = `${owner}#${facet}`;
    const version = (versions.get(key) ?? 0) + 1;
    versions.set(key, version);
    onLoading(owner, facet);
    try {
      const collection = await resolveCollection(owner, facet);
      if (versions.get(key) !== version) {
        return null;
      }
      onResolved(collection);
      return collection;
    } catch (error) {
      if (versions.get(key) !== version) {
        return null;
      }
      onError(owner, facet, error);
      throw error;
    }
  }

  return { load };
}

export async function resolveFacet(
  catalog,
  subject,
  facet,
  { fetchImpl = fetch, via = null } = {},
) {
  if (!subject || !facet) {
    throw new Error("A Subject and one of its Facets are required.");
  }
  const subjectRef = subject.ref ?? commandRef(subject);
  if (subjectRef.type === "instance" && facet.kind === "collection") {
    throw new Error("Nested Subject collections require recursive provenance and are not supported by v1.");
  }
  const body = { facet: facet.id, subject: subjectRef };
  if (subjectRef.type === "instance") {
    if (!via) {
      throw new Error("An instance Subject resolution requires its collection provenance.");
    }
    body.via = via;
  }
  const response = await fetchImpl("/api/v2/facet-resolutions", {
    body: JSON.stringify(body),
    cache: "no-store",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
    },
    method: "POST",
  });
  const document = await responseJson(response);
  if (facet.kind !== "collection") {
    return document;
  }
  return createSubjectCollection(document, catalog, subjectRef, facet);
}
