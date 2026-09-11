import {
  normalizeCommandIdentity,
  sameCommandIdentity,
} from "./command-identity.js";
import {
  canonicalFacetRoute,
  commandResourceRoute,
  normalizeFacetRoute,
} from "./resource-route.js";

export const PINNED_CONTEXT_SCHEMA = "swawkit.web-pinned-context/v2";
const CONTEXT_KIND = "$/system::context/contexts";
const FACET_ID = /^[a-z][a-z0-9-]{0,31}$/;
const SELECTOR = /^[a-z0-9][a-z0-9-]{0,127}$/;

function object(value, field) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${field} must be an object.`);
  }
  return value;
}

function exactKeys(value, expected, field) {
  const actual = Object.keys(value).sort();
  if (actual.length !== expected.length || actual.some((key, index) => key !== expected[index])) {
    throw new Error(`${field} has an invalid shape.`);
  }
}

function commandRef(value, field) {
  const reference = object(value, field);
  if (reference.type !== "command") {
    throw new Error(`${field} must identify a non-root Command Resource.`);
  }
  exactKeys(
    reference,
    reference.space === "module"
      ? ["address", "namespace", "space", "type"]
      : ["address", "space", "type"],
    field,
  );
  const identity = normalizeCommandIdentity(reference, field, (message) => new Error(message));
  if (identity.address.length === 0) {
    throw new Error(`${field} must identify a non-root Command Resource.`);
  }
  return identity.space === "system"
    ? { address: identity.address, space: identity.space, type: "command" }
    : {
        address: identity.address,
        namespace: identity.namespace,
        space: identity.space,
        type: "command",
      };
}

function contextIdentity(value, field) {
  const identity = object(value, field);
  exactKeys(identity, ["id", "kind", "type"], field);
  const kind = normalizeFacetRoute(identity.kind, `${field}.kind`, (message) => new Error(message));
  if (
    identity.type !== "instance"
    || canonicalFacetRoute(kind) !== CONTEXT_KIND
    || !SELECTOR.test(identity.id)
  ) {
    throw new Error(`${field} must identify a Context Resource.`);
  }
  return { id: identity.id, kind, type: "instance" };
}

export function createPinnedContextRecord(resource) {
  const identity = contextIdentity(resource?.identity, "resource.identity");
  const owner = commandRef(resource?.ownerRef, "resource.ownerRef");
  if (!FACET_ID.test(resource?.collectionFacet) || !SELECTOR.test(resource?.selector)) {
    throw new Error("resource provenance must contain a Facet and selector.");
  }
  return {
    schema: PINNED_CONTEXT_SCHEMA,
    identity,
    source: {
      facet: resource.collectionFacet,
      owner,
      selector: resource.selector,
    },
  };
}

export function parsePinnedContextRecord(serialized) {
  if (typeof serialized !== "string" || serialized.length === 0) {
    return null;
  }
  const value = object(JSON.parse(serialized), "pinned Context");
  exactKeys(value, ["identity", "schema", "source"], "pinned Context");
  if (value.schema !== PINNED_CONTEXT_SCHEMA) {
    throw new Error("pinned Context schema is unsupported.");
  }
  const source = object(value.source, "pinned Context.source");
  exactKeys(source, ["facet", "owner", "selector"], "pinned Context.source");
  return createPinnedContextRecord({
    collectionFacet: source.facet,
    identity: value.identity,
    ownerRef: source.owner,
    selector: source.selector,
  });
}

export function pinnedContextRef(record) {
  return `${commandResourceRoute(record.source.owner)}/${record.source.facet}::${record.source.selector}`;
}

export function contextAddInvocation(resource, command, document_) {
  if (
    !resource
    || resource.identity?.type !== "instance"
    || canonicalFacetRoute(resource.identity.kind) !== CONTEXT_KIND
    || !command?.address
  ) {
    return null;
  }
  if (document_?.commands?.some((candidate) => sameCommandIdentity(candidate, command))) {
    return { state: "present" };
  }
  const facet = resource.facets?.find((candidate) => candidate.id === "add");
  const resolver = facet?.resolver;
  if (
    facet?.kind !== "operation"
    || facet.renderer !== "run"
    || resolver?.type !== "command"
    || !resolver.acceptsTail
    || resolver.confirmation !== null
    || resolver.returns !== null
  ) {
    return null;
  }
  return {
    arguments: [command.address],
    route: `${resource.route}/${facet.id}`,
    state: "available",
  };
}
