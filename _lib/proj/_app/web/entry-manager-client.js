import { t } from "./i18n.js";
import {
  normalizeEntryInspection,
  normalizeEntryInventory,
  normalizeEntryMutation,
} from "./entry-manager-model.js";

const API_ROOT = "/api/v2/entries";
const CONTROL_HEADER = "X-SwawKit-Control";

export class EntryManagerClientError extends Error {}

async function responseError(response, action) {
  let detail = "";
  try {
    const document = await response.json();
    if (typeof document?.error === "string" && document.error.length > 0) {
      detail = `: ${document.error}`;
    }
  } catch {
    // Error response bodies are optional; status remains authoritative.
  }
  return new EntryManagerClientError(t(
    `${action}返回 HTTP ${response.status}${detail}`,
    `${action} returned HTTP ${response.status}${detail}`,
  ));
}

function entryRequest(entryName, control = null) {
  const headers = {
    Accept: "application/json",
    "Content-Type": "application/json",
  };
  if (control !== null) headers[CONTROL_HEADER] = control;
  return {
    method: "POST",
    headers,
    body: JSON.stringify({ entryName }),
  };
}

export async function readEntryInventory(fetchImpl = fetch) {
  const response = await fetchImpl(API_ROOT, {
    cache: "no-store",
    headers: { Accept: "application/json" },
  });
  if (!response.ok) {
    throw await responseError(response, t("读取 Entry 清单", "Entry inventory"));
  }
  return normalizeEntryInventory(await response.json());
}

export async function inspectEntryInstance(entryName, fetchImpl = fetch) {
  const response = await fetchImpl(
    `${API_ROOT}/inspect`,
    entryRequest(entryName),
  );
  if (!response.ok) {
    throw await responseError(response, t("检查 Entry", "Entry inspection"));
  }
  return normalizeEntryInspection(await response.json(), entryName);
}

async function mutateEntryInstance(operation, entryName, fetchImpl) {
  const path = operation === "create" ? API_ROOT : `${API_ROOT}/migrate`;
  const control = operation === "create"
    ? "entry-instance-create"
    : "entry-instance-migrate";
  const response = await fetchImpl(path, entryRequest(entryName, control));
  if (!response.ok) {
    throw await responseError(
      response,
      operation === "create" ? t("创建 Entry", "Entry creation") : t("迁移 Entry", "Entry migration"),
    );
  }
  return normalizeEntryMutation(await response.json(), operation, entryName);
}

export function createEntryInstance(entryName, fetchImpl = fetch) {
  return mutateEntryInstance("create", entryName, fetchImpl);
}

export function migrateEntryInstance(entryName, fetchImpl = fetch) {
  return mutateEntryInstance("migrate", entryName, fetchImpl);
}
