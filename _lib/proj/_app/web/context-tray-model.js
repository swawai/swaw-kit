export const PINNED_CONTEXT_SCHEMA = "swawkit.web-pinned-context/v1";

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
  exactKeys(reference, ["address", "source", "type"], field);
  if (
    reference.type !== "command"
    || !new Set(["control", "kernel", "action"]).has(reference.source)
    || typeof reference.address !== "string"
    || reference.address.length === 0
  ) {
    throw new Error(`${field} must identify a non-root command Subject.`);
  }
  return { address: reference.address, source: reference.source, type: "command" };
}

function contextRef(value, field) {
  const reference = object(value, field);
  exactKeys(reference, ["id", "kind", "type"], field);
  if (
    reference.type !== "instance"
    || reference.kind !== "context"
    || typeof reference.id !== "string"
    || !/^[a-z0-9][a-z0-9-]{0,127}$/.test(reference.id)
  ) {
    throw new Error(`${field} must identify a Context Subject.`);
  }
  return { id: reference.id, kind: "context", type: "instance" };
}

export function createPinnedContextRecord(subject) {
  const reference = contextRef(subject?.ref, "subject.ref");
  const via = object(subject?.via, "subject.via");
  const owner = commandRef(via.subject, "subject.via.subject");
  if (typeof via.facet !== "string" || !/^[a-z][a-z0-9-]{0,31}$/.test(via.facet)) {
    throw new Error("subject.via.facet must be a Facet id.");
  }
  return {
    schema: PINNED_CONTEXT_SCHEMA,
    subject: reference,
    via: { facet: via.facet, subject: owner },
  };
}

export function parsePinnedContextRecord(serialized) {
  if (typeof serialized !== "string" || serialized.length === 0) {
    return null;
  }
  const value = object(JSON.parse(serialized), "pinned Context");
  exactKeys(value, ["schema", "subject", "via"], "pinned Context");
  if (value.schema !== PINNED_CONTEXT_SCHEMA) {
    throw new Error("pinned Context schema is unsupported.");
  }
  const via = object(value.via, "pinned Context.via");
  exactKeys(via, ["facet", "subject"], "pinned Context.via");
  return createPinnedContextRecord({ ref: value.subject, via });
}

export function pinnedContextRef(record) {
  return `::context/${record.subject.id}`;
}

export function contextAddInvocation(subject, command, document_) {
  if (!subject || subject.ref?.kind !== "context" || !command?.address) {
    return null;
  }
  if (document_?.commands?.some((candidate) => (
    candidate.source === command.source && candidate.address === command.address
  ))) {
    return { state: "present" };
  }
  const facet = subject.facets?.find((candidate) => candidate.id === "add");
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
    address: resolver.address,
    arguments: [...resolver.arguments, command.address],
    state: "available",
  };
}
