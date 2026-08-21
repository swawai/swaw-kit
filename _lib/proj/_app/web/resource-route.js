import { normalizeCommandIdentity } from "./command-identity.js";

const FACET = /^[a-z][a-z0-9-]{0,31}$/;
const SELECTOR = /^[a-z0-9][a-z0-9-]{0,127}$/;

function invalid(message) {
  return new Error(message);
}

function requireObject(value, field, fail) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw fail(`${field} must be an object.`);
  }
  return value;
}

function exactKeys(value, allowed, field, fail) {
  const unknown = Object.keys(value).find((key) => !allowed.has(key));
  if (unknown) {
    throw fail(`${field}.${unknown} is not part of the Resource Route protocol.`);
  }
}

export function normalizeResourceRoute(value, field = "Resource route", fail = invalid) {
  const route = requireObject(value, field, fail);
  exactKeys(route, new Set(["hops"]), field, fail);
  if (!Array.isArray(route.hops) || route.hops.length > 32) {
    throw fail(`${field}.hops must contain at most 32 selections.`);
  }
  const hops = route.hops.map((rawHop, index) => {
    const hopField = `${field}.hops[${index}]`;
    const hop = requireObject(rawHop, hopField, fail);
    exactKeys(hop, new Set(["facet", "selector"]), hopField, fail);
    if (!FACET.test(hop.facet) || !SELECTOR.test(hop.selector)) {
      throw fail(`${hopField} must contain a portable Facet and selector.`);
    }
    return { facet: hop.facet, selector: hop.selector };
  });
  return { hops };
}

export function normalizeFacetRoute(value, field = "Facet route", fail = invalid) {
  const route = requireObject(value, field, fail);
  exactKeys(route, new Set(["resource", "facet"]), field, fail);
  if (!FACET.test(route.facet)) {
    throw fail(`${field}.facet must be a portable Facet id.`);
  }
  return {
    resource: normalizeResourceRoute(route.resource, `${field}.resource`, fail),
    facet: route.facet,
  };
}

export function canonicalResourceRoute(route) {
  const normalized = normalizeResourceRoute(route);
  return normalized.hops.reduce(
    (value, hop) => `${value}/${hop.facet}::${hop.selector}`,
    "$",
  );
}

export function canonicalFacetRoute(route) {
  const normalized = normalizeFacetRoute(route);
  return `${canonicalResourceRoute(normalized.resource)}/${normalized.facet}`;
}

export function commandResourceRoute(reference) {
  const identity = normalizeCommandIdentity(
    reference,
    "Command Resource",
    invalid,
  );
  let route;
  if (identity.space === "system") {
    if (identity.path.length === 0) {
      return "$";
    }
    route = `$/system::${identity.path[0]}`;
  } else {
    route = `$/modules::${identity.namespace}`;
  }
  const children = identity.space === "system"
    ? identity.path.slice(1)
    : identity.path;
  for (const child of children) {
    route += `/subcommands::${child}`;
  }
  return route;
}

export function commandFacetRoute(reference, facet) {
  if (reference.type !== "command") {
    throw new Error("A Command Resource ref is required.");
  }
  return `${commandResourceRoute(reference)}/${facet}`;
}
