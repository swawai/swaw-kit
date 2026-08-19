import { lstat, readFile } from "node:fs/promises";
import { join } from "node:path";
import {
  type BuildReleaseSet,
  PRODUCER_CONTRACT,
  PRODUCER_EXPORT,
  readBuildReleaseDirectory,
  requireControlledDirectory,
  RUNTIME_ARTIFACT_NAMES,
} from "./release-set.ts";

const STATE_SCHEMA = "swawkit.command-provider-state/v2";
const MAX_DOCUMENT_BYTES = 1024 * 1024;

type ReadyProviderState = {
  schema: string;
  status: string;
  inputRevision: string;
  token: string;
  exports: Array<{ id: string; contract: string }>;
};

export async function readReadyBuildReleaseSet(
  dataRoot: string,
  entryCommand: string,
): Promise<BuildReleaseSet> {
  try {
    return await readUnchecked(dataRoot, entryCommand);
  } catch (error) {
    if (error instanceof Error && error.message.startsWith("required Release Set")) throw error;
    const reason = error instanceof Error ? error.message : String(error);
    throw repairError(entryCommand, reason);
  }
}

async function readUnchecked(dataRoot: string, entryCommand: string): Promise<BuildReleaseSet> {
  const providerRoot = await requireControlledDirectory(
    dataRoot,
    ["modules", "project", "proj", "build", "app"],
    "project/proj/build/app provider",
  );
  const statePath = join(providerRoot, "_state.json");
  const exportRoot = await requireControlledDirectory(providerRoot, ["export"], "project/proj/build/app export");
  const initial = await readReadyState(statePath, entryCommand);
  const currentPath = join(exportRoot, "current");
  const id = parseSelector(await readBoundedRegularText(currentPath, 128));
  if (!id || initial.inputRevision !== `sha256-${id}`) {
    throw repairError(entryCommand, "its selector is invalid");
  }
  const root = await requireControlledDirectory(
    exportRoot,
    ["releases", id],
    "project/proj/build/app release",
  );
  const release = await readBuildReleaseDirectory(
    root,
    id,
    RUNTIME_ARTIFACT_NAMES,
  );
  const final = await readReadyState(statePath, entryCommand);
  const finalId = parseSelector(await readBoundedRegularText(currentPath, 128));
  if (!sameState(final, initial) || finalId !== id) {
    throw repairError(entryCommand, "it changed while being read");
  }
  return release;
}

async function readReadyState(path: string, entryCommand: string): Promise<ReadyProviderState> {
  let state: unknown;
  try {
    state = JSON.parse(await readBoundedRegularText(path, MAX_DOCUMENT_BYTES));
  } catch {
    throw repairError(entryCommand, "its Provider State is invalid");
  }
  if (
    !state || typeof state !== "object" || Array.isArray(state)
    || Object.keys(state).sort().join("\n")
      !== ["exports", "inputRevision", "schema", "status", "token"].sort().join("\n")
  ) throw repairError(entryCommand, "its Provider State is invalid");
  const value = state as Record<string, unknown>;
  if (
    value.schema !== STATE_SCHEMA || value.status !== "ready"
    || JSON.stringify(value.exports) !== JSON.stringify([
      { id: PRODUCER_EXPORT, contract: PRODUCER_CONTRACT },
    ])
    || typeof value.inputRevision !== "string"
    || !/^sha256-[a-f0-9]{64}$/.test(value.inputRevision)
    || typeof value.token !== "string" || !/^[a-f0-9]{32}$/.test(value.token)
  ) throw repairError(entryCommand, "it is not Ready for the expected contract");
  return value as ReadyProviderState;
}

function sameState(left: ReadyProviderState, right: ReadyProviderState): boolean {
  return left.schema === right.schema && left.status === right.status
    && left.inputRevision === right.inputRevision && left.token === right.token
    && JSON.stringify(left.exports) === JSON.stringify(right.exports);
}

function parseSelector(value: string): string | undefined {
  return /^([a-f0-9]{64})\r?\n$/.exec(value)?.[1];
}

async function readBoundedRegularText(path: string, maximum: number): Promise<string> {
  const metadata = await lstat(path);
  if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.size <= 0 || metadata.size > maximum) {
    throw new Error(`replaceable text file is invalid: ${path}`);
  }
  return readFile(path, "utf8");
}

function repairError(entryCommand: string, reason: string): Error {
  return new Error(
    `required Release Set from 'project/proj/build/app' is invalid because ${reason}; run '${entryCommand} project/proj/build/app'`,
  );
}
