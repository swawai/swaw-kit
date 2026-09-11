const SEGMENT = /^[a-z][a-z0-9-]{0,63}$/;
const RESERVED_NAMESPACES = new Set(["system", "module"]);

function fail(invalid, message) {
  throw invalid(message);
}

function pathSegments(value, field, invalid) {
  if (!Array.isArray(value) || value.some((segment) => !SEGMENT.test(segment))) {
    fail(invalid, `${field} must contain canonical command path segments.`);
  }
  return [...value];
}

export function normalizeCommandIdentity(
  value,
  field,
  invalid,
  { requirePath = false } = {},
) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    fail(invalid, `${field} must be an object.`);
  }
  if (value.space !== "system" && value.space !== "module") {
    fail(invalid, `${field}.space must be system or module.`);
  }
  if (typeof value.address !== "string") {
    fail(invalid, `${field}.address must be a string.`);
  }

  let path;
  if (value.path === undefined && !requirePath) {
    if (value.space === "system") {
      path = value.address === "" ? [] : value.address.slice(1).split("/");
    } else {
      const prefix = `${value.namespace}/`;
      path = value.address === value.namespace
        ? []
        : value.address.startsWith(prefix) ? value.address.slice(prefix.length).split("/") : [""];
    }
    if (path.some((segment) => !SEGMENT.test(segment))) {
      fail(invalid, `${field}.address is not canonical.`);
    }
  } else {
    path = pathSegments(value.path, `${field}.path`, invalid);
  }

  if (value.space === "system") {
    if (value.namespace !== null && value.namespace !== undefined) {
      fail(invalid, `${field}.namespace must be absent for a system command.`);
    }
    const address = path.length === 0 ? "" : `.${path.join("/")}`;
    if (value.address !== address) {
      fail(invalid, `${field}.address does not match its system path.`);
    }
    return { address, namespace: null, path, space: "system" };
  }

  const namespace = value.namespace;
  if (
    typeof namespace !== "string"
    || !SEGMENT.test(namespace)
    || RESERVED_NAMESPACES.has(namespace)
  ) {
    fail(invalid, `${field}.namespace must be a canonical module namespace.`);
  }
  const address = path.length === 0 ? namespace : `${namespace}/${path.join("/")}`;
  if (value.address !== address) {
    fail(invalid, `${field}.address does not match its module namespace and path.`);
  }
  return { address, namespace, path, space: "module" };
}

export function commandRef(command) {
  return command.space === "system"
    ? { address: command.address, space: "system", type: "command" }
    : {
        address: command.address,
        namespace: command.namespace,
        space: "module",
        type: "command",
      };
}

export function commandIdentityKey(command) {
  return command.space === "system"
    ? `system:${command.address}`
    : `module:${command.namespace}:${command.address}`;
}

export function sameCommandIdentity(left, right) {
  return left?.space === right?.space
    && (left?.namespace ?? null) === (right?.namespace ?? null)
    && left?.address === right?.address;
}
