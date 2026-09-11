import { afterEach, expect, test } from "bun:test";
import { mkdtemp, mkdir, readFile, rm, truncate, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readReadyBuildReleaseSet } from "./provider-release.ts";
import { publishBuildReleaseSet } from "./release-set.ts";
import { acquireExclusiveFileLock } from "./windows-filesystem.ts";

const temporaryRoots: string[] = [];
const COMMAND_RUNTIME_ID = "a".repeat(64);

afterEach(async () => {
  await Promise.all(
    temporaryRoots.splice(0).map((root) => rm(root, { recursive: true, force: true })),
  );
});

test("publishes the PowerShell-compatible immutable Release Set identity", async () => {
  const root = await temporaryRoot();
  const commandDataRoot = join(root, "command");
  const work = join(commandDataRoot, "work");
  await mkdir(work, { recursive: true });
  const candidates = {
    "swawkit-proj.exe": await candidate(work, "swawkit-proj.exe", "core"),
    "swawkit-proj-host.exe": await candidate(work, "swawkit-proj-host.exe", "host"),
    "swawkit-proj-module.exe": await candidate(work, "swawkit-proj-module.exe", "module"),
    "swawkit-proj-dev.exe": await candidate(work, "swawkit-proj-dev.exe", "dev"),
  };

  const id = await publishBuildReleaseSet(commandDataRoot, candidates, COMMAND_RUNTIME_ID);
  expect((await readFile(join(commandDataRoot, "export", "current"), "utf8")).trim()).toBe(id);
  const state = JSON.parse(await readFile(join(commandDataRoot, "_state.json"), "utf8"));
  expect(state).toMatchObject({
    schema: "swawkit.command-provider-state/v3",
    status: "ready",
    inputRevision: `sha256-${id}`,
  });
  expect(Object.keys(state).sort()).toEqual(["inputRevision", "schema", "status", "token"]);
  expect(await publishBuildReleaseSet(commandDataRoot, candidates, COMMAND_RUNTIME_ID)).toBe(id);
});

test("reads one coherent Ready Provider snapshot and rejects tampering", async () => {
  const root = await temporaryRoot();
  const dataRoot = join(root, "data");
  const commandDataRoot = join(dataRoot, "modules", "project", "proj", "build", "app");
  const work = join(commandDataRoot, "work");
  await mkdir(work, { recursive: true });
  const candidates = {
    "swawkit-proj.exe": await candidate(work, "swawkit-proj.exe", "core"),
    "swawkit-proj-host.exe": await candidate(work, "swawkit-proj-host.exe", "host"),
    "swawkit-proj-module.exe": await candidate(work, "swawkit-proj-module.exe", "module"),
    "swawkit-proj-dev.exe": await candidate(
      work,
      "swawkit-proj-dev.exe",
      "dev",
    ),
  };
  const id = await publishBuildReleaseSet(commandDataRoot, candidates, COMMAND_RUNTIME_ID);

  const release = await readReadyBuildReleaseSet(dataRoot, "fixture");
  expect(release.releaseId).toBe(id);
  expect(release.artifacts.map(({ name }) => name).sort()).toEqual(
    [
      "swawkit-proj-dev.exe",
      "swawkit-proj-host.exe",
      "swawkit-proj-module.exe",
      "swawkit-proj.exe",
    ],
  );

  const statePath = join(commandDataRoot, "_state.json");
  const readyState = await readFile(statePath, "utf8");
  await writeFile(statePath, JSON.stringify({
    ...JSON.parse(readyState),
    exports: [],
  }));
  expect(readReadyBuildReleaseSet(dataRoot, "fixture")).rejects.toThrow(
    "Provider State is invalid",
  );
  await writeFile(statePath, readyState);

  const unexpected = join(release.root, "unexpected.bin");
  await writeFile(unexpected, "unexpected");
  expect(readReadyBuildReleaseSet(dataRoot, "fixture")).rejects.toThrow(
    "run 'fixture project/proj/build/app'",
  );
  await rm(unexpected);

  await writeFile(join(release.root, "swawkit-proj-host.exe"), "evil");
  expect(readReadyBuildReleaseSet(dataRoot, "fixture")).rejects.toThrow(
    "run 'fixture project/proj/build/app'",
  );
});

test("rejects corruption in an existing immutable release", async () => {
  const root = await temporaryRoot();
  const commandDataRoot = join(root, "command");
  const work = join(commandDataRoot, "work");
  await mkdir(work, { recursive: true });
  const candidates = {
    "swawkit-proj.exe": await candidate(work, "swawkit-proj.exe", "core"),
    "swawkit-proj-host.exe": await candidate(work, "swawkit-proj-host.exe", "host"),
    "swawkit-proj-module.exe": await candidate(work, "swawkit-proj-module.exe", "module"),
    "swawkit-proj-dev.exe": await candidate(work, "swawkit-proj-dev.exe", "dev"),
  };
  const id = await publishBuildReleaseSet(commandDataRoot, candidates, COMMAND_RUNTIME_ID);
  await writeFile(
    join(commandDataRoot, "export", "releases", id, "swawkit-proj.exe"),
    "evil",
  );
  expect(publishBuildReleaseSet(commandDataRoot, candidates, COMMAND_RUNTIME_ID)).rejects.toThrow(
    "artifact is corrupt",
  );
  const state = JSON.parse(await readFile(join(commandDataRoot, "_state.json"), "utf8"));
  expect(state.status).toBe("unavailable");
  expect(state.schema).toBe("swawkit.command-provider-state/v3");
  expect(Object.keys(state).sort()).toEqual(["inputRevision", "schema", "status", "token"]);
});

test("rejects an empty Release Set", async () => {
  const root = await temporaryRoot();
  const commandDataRoot = join(root, "command");
  await mkdir(commandDataRoot, { recursive: true });
  expect(publishBuildReleaseSet(commandDataRoot, {} as never, COMMAND_RUNTIME_ID)).rejects.toThrow(
    "at least one artifact",
  );
});

test("rejects an oversized runtime artifact before hashing it", async () => {
  const root = await temporaryRoot();
  const commandDataRoot = join(root, "command");
  const work = join(commandDataRoot, "work");
  await mkdir(work, { recursive: true });
  const oversized = await candidate(work, "swawkit-proj.exe", "core");
  await truncate(oversized, 512 * 1024 * 1024 + 1);
  const candidates = {
    "swawkit-proj.exe": oversized,
    "swawkit-proj-host.exe": await candidate(work, "swawkit-proj-host.exe", "host"),
    "swawkit-proj-module.exe": await candidate(work, "swawkit-proj-module.exe", "module"),
    "swawkit-proj-dev.exe": await candidate(
      work,
      "swawkit-proj-dev.exe",
      "dev",
    ),
  };

  expect(publishBuildReleaseSet(commandDataRoot, candidates, COMMAND_RUNTIME_ID)).rejects.toThrow(
    "build candidate is invalid",
  );
});

test("build lock is exclusive and reusable by the same process", async () => {
  const root = await temporaryRoot();
  const path = join(root, "build.lock");
  const first = await acquireExclusiveFileLock(path, 100);
  try {
    expect(acquireExclusiveFileLock(path, 100)).rejects.toThrow("cannot acquire build lock");
  } finally {
    first[Symbol.dispose]();
  }
  const second = await acquireExclusiveFileLock(path, 100);
  second[Symbol.dispose]();
});

async function temporaryRoot(): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "swawkit-proj-build-"));
  temporaryRoots.push(root);
  return root;
}

async function candidate(root: string, name: string, content: string): Promise<string> {
  const path = join(root, name);
  await writeFile(path, content);
  return path;
}
