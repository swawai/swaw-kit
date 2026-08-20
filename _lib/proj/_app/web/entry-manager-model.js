export const ENTRY_INVENTORY_PROTOCOL = "swawkit.entry-inventory/v1";
export const ENTRY_INSTANCE_STATE_PROTOCOL = "swawkit.entry-instance-state/v1";
export const ENTRY_INSTANCE_MUTATION_PROTOCOL = "swawkit.entry-instance-mutation/v1";

const ENTRY_STATE_FIELDS = [
  "dataRoot",
  "entryFile",
  "entryId",
  "entryName",
  "issues",
  "releaseId",
  "status",
];
const INVENTORY_FIELDS = ["entries", "protocol", "swawkitHome"];
const INSPECTION_FIELDS = ["entry", "protocol"];
const MUTATION_FIELDS = ["changed", "entry", "operation", "protocol"];
const ENTRY_STATUSES = new Set([
  "available",
  "ready",
  "legacyMigrationRequired",
  "incomplete",
  "conflict",
]);
const OPERATIONS = new Set(["create", "migrate"]);
const SHA256 = /^[a-f0-9]{64}$/;
const CANONICAL_ENTRY_NAME = /^[a-z](?:[a-z0-9]*)(?:-[a-z0-9]+)*$/;
const DOS_DEVICE_ENTRY_NAME = /^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])$/;

export class EntryManagerProtocolError extends Error {}

function exactFields(value, expected, label) {
  if (
    typeof value !== "object"
    || value === null
    || Array.isArray(value)
    || Object.keys(value).sort().join("\0") !== expected.join("\0")
  ) {
    throw new EntryManagerProtocolError(`${label} has invalid fields.`);
  }
}

function requiredString(value, label) {
  if (typeof value !== "string" || value.length === 0) {
    throw new EntryManagerProtocolError(`${label} must be a non-empty string.`);
  }
  return value;
}

function nullableSha256(value, label) {
  if (!(value === null || (typeof value === "string" && SHA256.test(value)))) {
    throw new EntryManagerProtocolError(`${label} must be null or one SHA-256 value.`);
  }
  return value;
}

export function normalizeEntryState(value) {
  exactFields(value, ENTRY_STATE_FIELDS, "Entry state");
  const status = requiredString(value.status, "Entry state.status");
  if (!ENTRY_STATUSES.has(status)) {
    throw new EntryManagerProtocolError(`Entry state.status is unsupported: ${status}`);
  }
  if (!Array.isArray(value.issues) || value.issues.some(
    (issue) => typeof issue !== "string" || issue.length === 0,
  )) {
    throw new EntryManagerProtocolError("Entry state.issues must contain only non-empty strings.");
  }
  return {
    entryName: requiredString(value.entryName, "Entry state.entryName"),
    entryFile: requiredString(value.entryFile, "Entry state.entryFile"),
    dataRoot: requiredString(value.dataRoot, "Entry state.dataRoot"),
    status,
    entryId: nullableSha256(value.entryId, "Entry state.entryId"),
    releaseId: nullableSha256(value.releaseId, "Entry state.releaseId"),
    issues: [...value.issues],
  };
}

export function normalizeEntryInventory(value) {
  exactFields(value, INVENTORY_FIELDS, "Entry inventory");
  if (value.protocol !== ENTRY_INVENTORY_PROTOCOL) {
    throw new EntryManagerProtocolError(
      `Entry inventory protocol must be ${ENTRY_INVENTORY_PROTOCOL}.`,
    );
  }
  if (!Array.isArray(value.entries)) {
    throw new EntryManagerProtocolError("Entry inventory.entries must be an array.");
  }
  const entries = value.entries.map(normalizeEntryState);
  const names = new Set(entries.map((entry) => entry.entryName));
  if (names.size !== entries.length) {
    throw new EntryManagerProtocolError("Entry inventory contains duplicate Entry names.");
  }
  return {
    protocol: ENTRY_INVENTORY_PROTOCOL,
    swawkitHome: requiredString(value.swawkitHome, "Entry inventory.swawkitHome"),
    entries,
  };
}

export function normalizeEntryInspection(value, expectedEntryName = null) {
  exactFields(value, INSPECTION_FIELDS, "Entry inspection");
  if (value.protocol !== ENTRY_INSTANCE_STATE_PROTOCOL) {
    throw new EntryManagerProtocolError(
      `Entry inspection protocol must be ${ENTRY_INSTANCE_STATE_PROTOCOL}.`,
    );
  }
  const entry = normalizeEntryState(value.entry);
  if (expectedEntryName !== null && entry.entryName !== expectedEntryName) {
    throw new EntryManagerProtocolError("Entry inspection returned a different Entry name.");
  }
  return { protocol: ENTRY_INSTANCE_STATE_PROTOCOL, entry };
}

export function normalizeEntryMutation(value, expectedOperation, expectedEntryName = null) {
  exactFields(value, MUTATION_FIELDS, "Entry mutation");
  if (value.protocol !== ENTRY_INSTANCE_MUTATION_PROTOCOL) {
    throw new EntryManagerProtocolError(
      `Entry mutation protocol must be ${ENTRY_INSTANCE_MUTATION_PROTOCOL}.`,
    );
  }
  if (!OPERATIONS.has(value.operation) || value.operation !== expectedOperation) {
    throw new EntryManagerProtocolError("Entry mutation returned a different operation.");
  }
  if (typeof value.changed !== "boolean") {
    throw new EntryManagerProtocolError("Entry mutation.changed must be boolean.");
  }
  const entry = normalizeEntryState(value.entry);
  if (expectedEntryName !== null && entry.entryName !== expectedEntryName) {
    throw new EntryManagerProtocolError("Entry mutation returned a different Entry name.");
  }
  return {
    protocol: ENTRY_INSTANCE_MUTATION_PROTOCOL,
    operation: value.operation,
    changed: value.changed,
    entry,
  };
}

export function previewEntryPaths(swawkitHome, entryName) {
  if (typeof swawkitHome !== "string" || swawkitHome.length === 0) return null;
  if (
    typeof entryName !== "string"
    || entryName.length > 48
    || entryName === "swawkit"
    || DOS_DEVICE_ENTRY_NAME.test(entryName)
    || !CANONICAL_ENTRY_NAME.test(entryName)
  ) return null;
  const separator = swawkitHome.includes("\\") ? "\\" : "/";
  const join = (...parts) => parts.reduce(
    (path, part) => `${path}${path.endsWith("/") || path.endsWith("\\") ? "" : separator}${part}`,
  );
  return {
    entryFile: join(swawkitHome, `${entryName}.exe`),
    dataRoot: join(swawkitHome, "data", `proj.${entryName}`),
  };
}
