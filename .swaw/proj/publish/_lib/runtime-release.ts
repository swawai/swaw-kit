import { createHash, randomUUID } from "node:crypto";
import { copyFile, lstat, mkdir, open, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { basename, isAbsolute, join, relative, resolve } from "node:path";
import {
  type Artifact,
  type BuildReleaseSet,
  ensureControlledDirectory,
  requireControlledDirectory,
  RUNTIME_ARTIFACT_NAMES,
} from "../../build/_lib/release-set.ts";
import {
  acquireExclusiveFileLock,
  moveFileReplace,
} from "../../build/_lib/windows-filesystem.ts";

const RUNTIME_SCHEMA = "swawkit.proj-release-set/v4";
const COMMAND_RUNTIME_SCHEMA = "swawkit.proj-command-runtime/v1";
const MAX_MANIFEST_BYTES = 1024 * 1024;
const MAX_ARTIFACT_BYTES = 512 * 1024 * 1024;

export async function publishRuntimeReleaseSet(
  projHome: string,
  dataRoot: string,
  cacheDataRoot: string,
  release: BuildReleaseSet,
): Promise<string> {
  if (releaseIdentity(release.artifacts, release.commandRuntimeId) !== release.releaseId) {
    throw new Error("the application Release Set ID does not match its artifacts");
  }
  await validateCommandRuntime(projHome, release.commandRuntimeId);
  const ownerDataRoot = await requireControlledDirectory(dataRoot, [], "entry DataRoot");
  const runtimeRoot = await ensureControlledDirectory(ownerDataRoot, ["runtime"], "runtime root");
  const cacheRoot = await ensureControlledDirectory(cacheDataRoot, [], "shared cache");
  const locks = await ensureControlledDirectory(cacheRoot, ["locks"], "runtime locks");
  using lock = await acquireExclusiveFileLock(join(locks, "release-publish.lock"), 120_000);
  const releasesRoot = await ensureControlledDirectory(runtimeRoot, ["releases"], "runtime releases");
  const target = join(releasesRoot, release.releaseId);
  if (await missing(target)) {
    await publishDirectory(releasesRoot, target, release);
  }
  await validateRuntimeRelease(target, release);
  await publishSelector(runtimeRoot, release.releaseId);
  return release.releaseId;
}

function releaseIdentity(artifacts: Artifact[], commandRuntimeId: string): string {
  if (!/^[a-f0-9]{64}$/.test(commandRuntimeId)) {
    throw new Error("the application Command Runtime ID is invalid");
  }
  const records = new Map(artifacts.map((artifact) => [artifact.name, artifact]));
  if (records.size !== RUNTIME_ARTIFACT_NAMES.length) {
    throw new Error("the application Release Set has invalid membership");
  }
  const identity = [RUNTIME_SCHEMA, commandRuntimeId];
  for (const name of RUNTIME_ARTIFACT_NAMES) {
    const artifact = records.get(name);
    if (!artifact) throw new Error("the application Release Set has invalid membership");
    if (
      !Number.isSafeInteger(artifact.length)
      || artifact.length <= 0
      || artifact.length > MAX_ARTIFACT_BYTES
      || !/^[a-f0-9]{64}$/.test(artifact.sha256)
    ) throw new Error(`the application Release Set artifact is invalid: ${artifact.path}`);
    identity.push(name, String(artifact.length), artifact.sha256);
  }
  return createHash("sha256").update(identity.join("\n")).digest("hex");
}

async function publishDirectory(
  releasesRoot: string,
  target: string,
  release: BuildReleaseSet,
): Promise<void> {
  const stage = join(releasesRoot, `.${release.releaseId}.${randomUUID().replaceAll("-", "")}.tmp`);
  await mkdir(stage);
  let committed = false;
  try {
    for (const artifact of release.artifacts) {
      await copyFile(artifact.path, join(stage, artifact.name));
    }
    await writeFile(join(stage, "manifest.json"), json({
      schema: RUNTIME_SCHEMA,
      releaseId: release.releaseId,
      commandRuntimeId: release.commandRuntimeId,
      artifacts: release.artifacts.map(({ name, length, sha256 }) => ({ name, length, sha256 })),
    }), { flag: "wx" });
    await validateRuntimeRelease(stage, release, false);
    try {
      await rename(stage, target);
      committed = true;
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code;
      if (code !== "EEXIST" && code !== "EPERM") throw error;
      await validateRuntimeRelease(target, release);
    }
  } finally {
    if (!committed) await rm(stage, { recursive: true, force: true });
  }
}

async function validateRuntimeRelease(
  root: string,
  expected: BuildReleaseSet,
  requireReleaseLeaf = true,
): Promise<void> {
  const metadata = await lstat(root);
  if (!metadata.isDirectory() || metadata.isSymbolicLink()) {
    throw new Error(`runtime Release Set directory is unsafe: ${root}`);
  }
  if (requireReleaseLeaf && basename(root) !== expected.releaseId) {
    throw new Error(`runtime Release Set path is invalid: ${root}`);
  }
  const members = (await readdir(root)).sort();
  const expectedMembers = [...RUNTIME_ARTIFACT_NAMES, "manifest.json"].sort();
  if (members.join("\n") !== expectedMembers.join("\n")) {
    throw new Error(`runtime Release Set directory membership is invalid: ${root}`);
  }
  const manifestPath = join(root, "manifest.json");
  const manifestMetadata = await lstat(manifestPath);
  if (
    !manifestMetadata.isFile()
    || manifestMetadata.isSymbolicLink()
    || manifestMetadata.size <= 0
    || manifestMetadata.size > MAX_MANIFEST_BYTES
  ) {
    throw new Error(`runtime Release Set manifest is invalid: ${manifestPath}`);
  }
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  if (
    !manifest || typeof manifest !== "object" || Array.isArray(manifest)
    || Object.keys(manifest).sort().join("\n")
      !== ["artifacts", "commandRuntimeId", "releaseId", "schema"].sort().join("\n")
    || manifest.schema !== RUNTIME_SCHEMA
    || manifest.releaseId !== expected.releaseId
    || manifest.commandRuntimeId !== expected.commandRuntimeId
    || !Array.isArray(manifest.artifacts)
  ) {
    throw new Error(`runtime Release Set manifest is invalid: ${manifestPath}`);
  }
  const records = new Map<string, Artifact>();
  for (const record of manifest.artifacts) {
    if (
      !record || typeof record !== "object" || Array.isArray(record)
      || Object.keys(record).sort().join("\n") !== ["length", "name", "sha256"].join("\n")
      || typeof record.name !== "string"
      || !Number.isSafeInteger(record.length) || record.length <= 0
      || record.length > MAX_ARTIFACT_BYTES
      || typeof record.sha256 !== "string" || !/^[a-f0-9]{64}$/.test(record.sha256)
      || records.has(record.name)
    ) throw new Error(`runtime Release Set manifest is invalid: ${manifestPath}`);
    records.set(record.name, record);
  }
  for (const artifact of expected.artifacts) {
    const record = records.get(artifact.name);
    const path = join(root, artifact.name);
    const item = await lstat(path);
    if (
      !record || !item.isFile() || item.isSymbolicLink()
      || item.size <= 0 || item.size > MAX_ARTIFACT_BYTES
      || item.size !== artifact.length || record.length !== artifact.length
      || record.sha256 !== artifact.sha256
    ) throw new Error(`runtime Release Set artifact is corrupt: ${path}`);
    const bytes = await readFile(path);
    const actual = new Bun.CryptoHasher("sha256").update(bytes).digest("hex");
    if (actual !== artifact.sha256) {
      throw new Error(`runtime Release Set artifact is corrupt: ${path}`);
    }
  }
  if (records.size !== RUNTIME_ARTIFACT_NAMES.length) {
    throw new Error(`runtime Release Set has invalid membership: ${manifestPath}`);
  }
}

async function validateCommandRuntime(projHome: string, id: string): Promise<void> {
  if (!/^[a-f0-9]{64}$/.test(id)) throw new Error("Command Runtime ID is invalid");
  const bootstrapRoot = resolve(projHome, "data", "proj_cache", "bootstrap");
  const root = resolve(bootstrapRoot, "command-runtimes", "releases", id);
  const rootMetadata = await lstat(root);
  if (!rootMetadata.isDirectory() || rootMetadata.isSymbolicLink()) {
    throw new Error(`Command Runtime release is unsafe: ${root}`);
  }
  if ((await readdir(root)).sort().join("\n") !== "manifest.json") {
    throw new Error(`Command Runtime release membership is invalid: ${root}`);
  }
  const manifestPath = join(root, "manifest.json");
  const metadata = await lstat(manifestPath);
  if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.size <= 0 || metadata.size > 64 * 1024) {
    throw new Error(`Command Runtime manifest is invalid: ${manifestPath}`);
  }
  const document = JSON.parse(await readFile(manifestPath, "utf8"));
  if (
    !document || typeof document !== "object" || Array.isArray(document)
    || Object.keys(document).sort().join("\n") !== ["runtimeId", "schema", "tools"].join("\n")
    || document.schema !== COMMAND_RUNTIME_SCHEMA || document.runtimeId !== id
    || !Array.isArray(document.tools) || document.tools.length !== 2
  ) throw new Error(`Command Runtime manifest is invalid: ${manifestPath}`);
  const identity = [COMMAND_RUNTIME_SCHEMA];
  const names = new Set<string>();
  for (const tool of [...document.tools].sort((left, right) =>
    String(left.name) < String(right.name) ? -1 : String(left.name) > String(right.name) ? 1 : 0
  )) {
    if (
      !tool || typeof tool !== "object" || Array.isArray(tool)
      || Object.keys(tool).sort().join("\n") !== ["length", "name", "path", "sha256", "version"].join("\n")
      || typeof tool.name !== "string" || !["bun", "pwsh"].includes(tool.name)
      || names.has(tool.name)
      || typeof tool.version !== "string" || !/^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$/.test(tool.version)
      || typeof tool.path !== "string" || !/^[A-Za-z0-9._+-]+(?:\/[A-Za-z0-9._+ -]+)*$/.test(tool.path)
      || !Number.isSafeInteger(tool.length) || tool.length <= 0 || tool.length > MAX_ARTIFACT_BYTES
      || typeof tool.sha256 !== "string" || !/^[a-f0-9]{64}$/.test(tool.sha256)
    ) throw new Error(`Command Runtime tool record is invalid: ${manifestPath}`);
    names.add(tool.name);
    const path = resolve(bootstrapRoot, ...tool.path.split("/"));
    const child = relative(bootstrapRoot, path);
    if (!child || child.startsWith("..") || isAbsolute(child)) {
      throw new Error(`Command Runtime tool escaped its root: ${path}`);
    }
    const item = await lstat(path);
    const bytes = await readFile(path);
    const hash = createHash("sha256").update(bytes).digest("hex");
    if (!item.isFile() || item.isSymbolicLink() || item.size !== tool.length || hash !== tool.sha256) {
      throw new Error(`Command Runtime tool is corrupt: ${path}`);
    }
    identity.push(tool.name, tool.version, tool.path, String(tool.length), tool.sha256);
  }
  if (names.size !== 2 || !names.has("bun") || !names.has("pwsh")
    || createHash("sha256").update(identity.join("\n")).digest("hex") !== id) {
    throw new Error(`Command Runtime identity is invalid: ${manifestPath}`);
  }
}

async function publishSelector(runtimeRoot: string, id: string): Promise<void> {
  const current = join(runtimeRoot, "current");
  try {
    const metadata = await lstat(current);
    if (!metadata.isFile() || metadata.isSymbolicLink()) {
      throw new Error(`runtime Release Set selector is unsafe: ${current}`);
    }
    if (metadata.size <= 128 && (await readFile(current, "utf8")) === `${id}\n`) return;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
  const stage = join(runtimeRoot, `.current.${randomUUID().replaceAll("-", "")}.tmp`);
  const file = await open(stage, "wx");
  try {
    await file.writeFile(`${id}\n`);
    await file.sync();
  } finally {
    await file.close();
  }
  moveFileReplace(stage, current);
}

async function missing(path: string): Promise<boolean> {
  try {
    await lstat(path);
    return false;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return true;
    throw error;
  }
}

function json(value: unknown): string {
  return `${JSON.stringify(value, null, 2).replaceAll("\n", "\r\n")}\r\n`;
}
