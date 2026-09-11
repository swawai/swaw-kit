import { normalizeFacets } from "./facet-model.js";
import { normalizeFacetRoute } from "./resource-route.js";

const TOKEN = /^[a-z][a-z0-9-]{0,31}$/;
const INSTANCE_ID = /^[a-z0-9][a-z0-9-]{0,127}$/;

function object(value, field, invalid) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw invalid(`${field} must be an object.`);
  }
  return value;
}

function templateArgument(value, field, invalid) {
  if (typeof value === "string") {
    if (value.length > 4096 || value.includes("\0")) {
      throw invalid(`${field} literal is invalid.`);
    }
    return value;
  }
  const binding = object(value, field, invalid);
  if (Object.keys(binding).length !== 1 || binding.bind !== "resource.selector") {
    throw invalid(`${field} must bind resource.selector.`);
  }
  return { bind: "resource.selector" };
}

export function normalizeResourceKinds(value, field, invalid) {
  if (!Array.isArray(value) || value.length > 8) {
    throw invalid(`${field} must contain at most 8 Resource Kind templates.`);
  }
  const kinds = new Set();
  return value.map((rawKind, kindIndex) => {
    const kindField = `${field}[${kindIndex}]`;
    const resourceKind = object(rawKind, kindField, invalid);
    if (!TOKEN.test(resourceKind.kind) || kinds.has(resourceKind.kind)) {
      throw invalid(`${kindField}.kind must be unique and match [a-z][a-z0-9-]{0,31}.`);
    }
    kinds.add(resourceKind.kind);
    if (
      !Array.isArray(resourceKind.facets)
      || resourceKind.facets.length === 0
      || resourceKind.facets.length > 32
    ) {
      throw invalid(`${kindField}.facets must contain 1 to 32 templates.`);
    }
    const materialized = resourceKind.facets.map((rawFacet, facetIndex) => {
      const facetField = `${kindField}.facets[${facetIndex}]`;
      const facet = object(rawFacet, facetField, invalid);
      const resolver = object(facet.resolver, `${facetField}.resolver`, invalid);
      if (resolver.type !== "command" || !Array.isArray(resolver.arguments)) {
        throw invalid(`${facetField} must declare a command resolver.`);
      }
      const argumentsTemplate = resolver.arguments.map((argument, argumentIndex) => (
        templateArgument(argument, `${facetField}.resolver.arguments[${argumentIndex}]`, invalid)
      ));
      const concrete = {
        ...facet,
        resolver: {
          ...resolver,
          arguments: argumentsTemplate.map((argument) => (
            typeof argument === "string" ? argument : "resource"
          )),
        },
      };
      const normalized = normalizeFacets([concrete], facetField, invalid)[0];
      if (
        normalized.kind === "collection"
        || (normalized.kind === "operation" && normalized.renderer !== "run")
        || normalized.resolver?.type !== "command"
      ) {
        throw invalid(`${facetField} is not a supported instance Facet template.`);
      }
      return {
        ...normalized,
        resolver: { ...normalized.resolver, arguments: argumentsTemplate },
      };
    });
    const facetIds = new Set();
    for (const facet of materialized) {
      if (facetIds.has(facet.id)) {
        throw invalid(`${kindField}.facets contains duplicate ids.`);
      }
      facetIds.add(facet.id);
    }
    return {
      facets: materialized,
      kind: resourceKind.kind,
      source: normalizeFacetRoute(resourceKind.source, `${kindField}.source`, invalid),
    };
  });
}

export function instantiateResourceFacets(resourceKind, facetIds, resourceSelector, invalid) {
  if (!INSTANCE_ID.test(resourceSelector)) {
    throw invalid("Resource id is invalid.");
  }
  const templates = new Map(resourceKind.facets.map((facet) => [facet.id, facet]));
  return facetIds.map((facetId) => {
    const template = templates.get(facetId);
    if (!template) {
      throw invalid(`Resource exposes unknown Facet '${facetId}'.`);
    }
    return {
      ...template,
      resolver: {
        ...template.resolver,
        arguments: template.resolver.arguments.map((argument) => (
          typeof argument === "string" ? argument : resourceSelector
        )),
      },
    };
  });
}
