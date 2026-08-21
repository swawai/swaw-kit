import { instantiateResourceFacets } from "./resource-kind-model.js";
import { commandRef } from "./command-identity.js";
import {
  canonicalFacetRoute,
  canonicalResourceRoute,
  commandFacetRoute,
  normalizeFacetRoute,
  normalizeResourceRoute,
} from "./resource-route.js";

const RESOURCE_LIST_PROTOCOL = "swawkit.resource-list/v2";
const FACET_ID = /^[a-z][a-z0-9-]{0,31}$/;
const SELECTOR = /^[a-z0-9][a-z0-9-]{0,127}$/;

function invalid(message) {
  return new Error(`Invalid Resource List protocol: ${message}`);
}

function object(value, field) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw invalid(`${field} must be an object.`);
  }
  return value;
}

function exactKeys(value, allowed, field) {
  const unknown = Object.keys(value).find((key) => !allowed.has(key));
  if (unknown) {
    throw invalid(`${field}.${unknown} is not part of Resource List v2.`);
  }
}

function text(value, field, maximum, allowEmpty = false) {
  if (
    typeof value !== "string"
    || (!allowEmpty && value.length === 0)
    || value.trim() !== value
    || [...value].length > maximum
  ) {
    throw invalid(`${field} must be a trimmed string of at most ${maximum} characters.`);
  }
  return value;
}

function normalizeIdentity(value, field) {
  const identity = object(value, field);
  if (identity.type === "static") {
    exactKeys(identity, new Set(["type", "route"]), field);
    return {
      type: "static",
      route: normalizeResourceRoute(identity.route, `${field}.route`, invalid),
    };
  }
  if (identity.type === "instance") {
    exactKeys(identity, new Set(["type", "kind", "id"]), field);
    if (!SELECTOR.test(identity.id)) {
      throw invalid(`${field}.id must be a portable Resource id.`);
    }
    return {
      type: "instance",
      kind: normalizeFacetRoute(identity.kind, `${field}.kind`, invalid),
      id: identity.id,
    };
  }
  throw invalid(`${field}.type is not supported.`);
}

function identityKey(identity) {
  return identity.type === "static"
    ? `static:${canonicalResourceRoute(identity.route)}`
    : `instance:${canonicalFacetRoute(identity.kind)}::${identity.id}`;
}

export function createResourceList(document, catalog, owner, collectionFacet) {
  const payload = object(document, "Resource List");
  exactKeys(payload, new Set(["protocol", "source", "resources"]), "Resource List");
  if (payload.protocol !== RESOURCE_LIST_PROTOCOL) {
    throw invalid(`protocol must be ${RESOURCE_LIST_PROTOCOL}.`);
  }
  const catalogResolved = collectionFacet?.kind === "collection"
    && collectionFacet.resolver?.type === "catalog"
    && collectionFacet.resolver.relation === "subcommands"
    && collectionFacet.resourceKind === null;
  const commandResolved = collectionFacet?.kind === "collection"
    && collectionFacet.resolver?.type === "command"
    && collectionFacet.resolver.returns === RESOURCE_LIST_PROTOCOL
    && collectionFacet.resourceKind !== null;
  if (!owner || (!catalogResolved && !commandResolved)) {
    throw invalid("the selected Facet does not resolve a Resource List.");
  }

  const source = normalizeFacetRoute(payload.source, "source", invalid);
  const sourceRoute = canonicalFacetRoute(source);
  if (sourceRoute !== commandFacetRoute(commandRef(owner), collectionFacet.id)) {
    throw invalid("source does not match the requested Collection Facet.");
  }
  const kindSource = commandResolved
    ? canonicalFacetRoute(collectionFacet.resourceKind.source)
    : null;
  const provider = kindSource === null
    ? null
    : catalog.resourceKindBySource.get(kindSource);
  if (kindSource !== null && (
    !provider
    || canonicalFacetRoute(provider.resourceKind.source) !== kindSource
  )) {
    throw invalid("Collection Resource Kind provider is unavailable.");
  }
  if (!Array.isArray(payload.resources) || payload.resources.length > 1024) {
    throw invalid("resources must contain at most 1024 listings.");
  }

  const selectors = new Set();
  const routes = new Set();
  const identities = new Set();
  const resources = payload.resources.map((raw, index) => {
    const field = `resources[${index}]`;
    const listing = object(raw, field);
    exactKeys(
      listing,
      new Set(["identity", "selector", "route", "facetIds", "label", "summary"]),
      field,
    );
    if (!SELECTOR.test(listing.selector) || selectors.has(listing.selector)) {
      throw invalid(`${field}.selector must be unique and portable.`);
    }
    selectors.add(listing.selector);
    const route = normalizeResourceRoute(listing.route, `${field}.route`, invalid);
    const routeValue = canonicalResourceRoute(route);
    const expectedRoute = `${canonicalResourceRoute(source.resource)}/${source.facet}::${listing.selector}`;
    if (routeValue !== expectedRoute || routes.has(routeValue)) {
      throw invalid(`${field}.route must record its unique Collection selection.`);
    }
    routes.add(routeValue);

    const identity = normalizeIdentity(listing.identity, `${field}.identity`);
    const key = identityKey(identity);
    if (identities.has(key)) {
      throw invalid(`${field}.identity is duplicated.`);
    }
    identities.add(key);
    if (
      !Array.isArray(listing.facetIds)
      || listing.facetIds.length > 32
      || listing.facetIds.some((facetId) => !FACET_ID.test(facetId))
      || new Set(listing.facetIds).size !== listing.facetIds.length
    ) {
      throw invalid(`${field}.facetIds must contain at most 32 unique Facet ids.`);
    }
    let command = null;
    let facets;
    let id;
    if (catalogResolved) {
      if (
        identity.type !== "static"
        || canonicalResourceRoute(identity.route) !== routeValue
      ) {
        throw invalid(`${field}.identity does not identify its static Resource route.`);
      }
      command = catalog.commandByResourceRoute.get(routeValue) ?? null;
      if (!command || command.parent !== owner.address) {
        throw invalid(`${field}.identity is not a direct Catalog subcommand.`);
      }
      const declared = new Set(command.facets.map((facet) => facet.id));
      if (
        declared.size !== listing.facetIds.length
        || listing.facetIds.some((facetId) => !declared.has(facetId))
      ) {
        throw invalid(`${field}.facetIds do not match the static Resource Facets.`);
      }
      facets = command.facets;
      id = listing.selector;
    } else {
      if (
        identity.type !== "instance"
        || identity.id !== listing.selector
        || canonicalFacetRoute(identity.kind) !== kindSource
      ) {
        throw invalid(`${field}.identity does not belong to the Collection Resource Kind.`);
      }
      facets = instantiateResourceFacets(
        provider.resourceKind,
        listing.facetIds,
        identity.id,
        invalid,
      );
      id = identity.id;
    }
    return {
      collectionFacet: collectionFacet.id,
      command,
      facets,
      id,
      identity,
      identityKey: key,
      label: text(listing.label, `${field}.label`, 128),
      owner: owner.address,
      ownerRef: commandRef(owner),
      route: routeValue,
      selector: listing.selector,
      summary: text(listing.summary, `${field}.summary`, 500, true),
    };
  });
  return {
    facet: collectionFacet.id,
    label: collectionFacet.label,
    owner: owner.address,
    protocol: RESOURCE_LIST_PROTOCOL,
    resourceByRoute: new Map(resources.map((resource) => [resource.route, resource])),
    resourceBySelector: new Map(resources.map((resource) => [resource.selector, resource])),
    resources,
    source: sourceRoute,
  };
}
