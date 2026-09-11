import { afterEach, expect, test } from "bun:test";
import {
  copyFile,
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readReadyBuildReleaseSet } from "../../build/_lib/provider-release.ts";
import { publishBuildReleaseSet } from "../../build/_lib/release-set.ts";
import { publishRuntimeReleaseSet } from "./runtime-release.ts";

const temporaryRoots: string[] = [];

afterEach(async () => {
  await Promise.all(
    temporaryRoots.splice(0).map((root) => rm(root, { recursive: true, force: true })),
  );
});

test("atomically selects a new runtime while the previous release remains mapped", async () => {
  const fixture = await runtimeFixture();
  const previous = await publishFixtureRelease(fixture, {
    "swawkit-proj.exe": systemExecutable("cmd.exe"),
    "swawkit-proj-host.exe": systemExecutable("where.exe"),
    "swawkit-proj-module.exe": systemExecutable("hostname.exe"),
    "swawkit-proj-dev.exe": systemExecutable("whoami.exe"),
  });
  const running = Bun.spawn(
    [
      join(fixture.runtimeRoot, "releases", previous, "swawkit-proj.exe"),
      "/d",
      "/c",
      "ping -n 8 127.0.0.1 >nul",
    ],
    { stdout: "ignore", stderr: "ignore", windowsHide: true },
  );
  try {
    await Bun.sleep(400);
    expect(running.exitCode).toBeNull();

    const current = await publishFixtureRelease(fixture, {
      "swawkit-proj.exe": systemExecutable("where.exe"),
      "swawkit-proj-host.exe": systemExecutable("whoami.exe"),
      "swawkit-proj-module.exe": systemExecutable("cmd.exe"),
      "swawkit-proj-dev.exe": systemExecutable("hostname.exe"),
    });
    expect(current).not.toBe(previous);
    expect(running.exitCode).toBeNull();
    expect(await readFile(join(fixture.runtimeRoot, "current"), "utf8")).toBe(`${current}\n`);
    expect(await readFile(join(fixture.runtimeRoot, "releases", current, "manifest.json"), "utf8"))
      .toContain(current);
    for (const name of [
      "swawkit-proj.exe",
      "swawkit-proj-host.exe",
      "swawkit-proj-module.exe",
      "swawkit-proj-dev.exe",
    ]) {
      await expect(lstat(join(fixture.runtimeRoot, name))).rejects.toMatchObject({ code: "ENOENT" });
    }

    const releaseRoot = join(fixture.runtimeRoot, "releases", current);
    const before = (await lstat(releaseRoot)).birthtimeMs;
    const selected = await readReadyBuildReleaseSet(fixture.dataRoot, "fixture");
    await writeFile(join(fixture.runtimeRoot, "current"), "invalid".repeat(1024));
    expect(await publishRuntimeReleaseSet(
      fixture.home,
      fixture.dataRoot,
      fixture.cacheRoot,
      selected,
    )).toBe(current);
    expect(await readFile(join(fixture.runtimeRoot, "current"), "utf8")).toBe(`${current}\n`);
    expect((await lstat(releaseRoot)).birthtimeMs).toBe(before);
    expect((await readdir(fixture.runtimeRoot)).filter((name) => name.startsWith("."))).toEqual([]);

    const unexpected = join(releaseRoot, "unexpected.bin");
    await writeFile(unexpected, "unexpected");
    expect(publishRuntimeReleaseSet(
      fixture.home,
      fixture.dataRoot,
      fixture.cacheRoot,
      selected,
    )).rejects.toThrow(
      "directory membership is invalid",
    );
    await rm(unexpected);

    await writeFile(join(releaseRoot, "swawkit-proj-host.exe"), "coherently-tampered-host");
    expect(publishRuntimeReleaseSet(
      fixture.home,
      fixture.dataRoot,
      fixture.cacheRoot,
      selected,
    )).rejects.toThrow(
      "artifact is corrupt",
    );
  } finally {
    running.kill();
    await running.exited;
  }
});

test("rejects a runtime releases parent junction", async () => {
  const fixture = await runtimeFixture();
  const external = join(fixture.root, "external-releases");
  await mkdir(fixture.runtimeRoot, { recursive: true });
  await mkdir(external);
  await symlink(external, join(fixture.runtimeRoot, "releases"), "junction");
  const release = await buildFixtureRelease(fixture, {
    "swawkit-proj.exe": systemExecutable("where.exe"),
    "swawkit-proj-host.exe": systemExecutable("whoami.exe"),
    "swawkit-proj-module.exe": systemExecutable("cmd.exe"),
    "swawkit-proj-dev.exe": systemExecutable("hostname.exe"),
  });

  expect(publishRuntimeReleaseSet(
    fixture.home,
    fixture.dataRoot,
    fixture.cacheRoot,
    release,
  )).rejects.toThrow(
    "runtime releases must be a regular directory",
  );
  expect(await readdir(external)).toEqual([]);
});

test("keeps each entry DataRoot selector isolated and never creates the legacy _bin", async () => {
  const fixture = await runtimeFixture();
  const secondDataRoot = join(fixture.root, "second-entry-data");
  await mkdir(secondDataRoot);

  const firstRelease = await buildFixtureRelease(fixture, {
    "swawkit-proj.exe": systemExecutable("cmd.exe"),
    "swawkit-proj-host.exe": systemExecutable("where.exe"),
    "swawkit-proj-module.exe": systemExecutable("hostname.exe"),
    "swawkit-proj-dev.exe": systemExecutable("whoami.exe"),
  });
  const firstId = await publishRuntimeReleaseSet(
    fixture.home,
    fixture.dataRoot,
    fixture.cacheRoot,
    firstRelease,
  );

  const secondRelease = await buildFixtureRelease(fixture, {
    "swawkit-proj.exe": systemExecutable("where.exe"),
    "swawkit-proj-host.exe": systemExecutable("whoami.exe"),
    "swawkit-proj-module.exe": systemExecutable("cmd.exe"),
    "swawkit-proj-dev.exe": systemExecutable("hostname.exe"),
  });
  const secondId = await publishRuntimeReleaseSet(
    fixture.home,
    secondDataRoot,
    fixture.cacheRoot,
    secondRelease,
  );

  expect(secondId).not.toBe(firstId);
  expect(await readFile(join(fixture.dataRoot, "runtime", "current"), "utf8"))
    .toBe(`${firstId}\n`);
  expect(await readFile(join(secondDataRoot, "runtime", "current"), "utf8"))
    .toBe(`${secondId}\n`);
  await expect(lstat(join(fixture.home, "_lib", "proj", "_bin")))
    .rejects.toMatchObject({ code: "ENOENT" });
});

type Fixture = Awaited<ReturnType<typeof runtimeFixture>>;
type Candidates = Record<
  | "swawkit-proj.exe"
  | "swawkit-proj-host.exe"
  | "swawkit-proj-module.exe"
  | "swawkit-proj-dev.exe",
  string
>;

async function runtimeFixture() {
  const root = await mkdtemp(join(tmpdir(), "swawkit-proj-publish-"));
  temporaryRoots.push(root);
  const home = join(root, "home");
  const dataRoot = join(root, "data");
  const commandRoot = join(dataRoot, "modules", "project", "proj", "build", "app");
  const cacheRoot = join(home, "data", "proj_cache");
  const runtimeRoot = join(dataRoot, "runtime");
  await mkdir(dataRoot, { recursive: true });
  await mkdir(cacheRoot, { recursive: true });
  const commandRuntimeId = await writeCommandRuntime(home);
  return {
    root,
    home,
    dataRoot,
    commandRoot,
    cacheRoot,
    runtimeRoot,
    commandRuntimeId,
    generation: 0,
  };
}

async function publishFixtureRelease(fixture: Fixture, sources: Candidates): Promise<string> {
  const release = await buildFixtureRelease(fixture, sources);
  return publishRuntimeReleaseSet(
    fixture.home,
    fixture.dataRoot,
    fixture.cacheRoot,
    release,
  );
}

async function buildFixtureRelease(fixture: Fixture, sources: Candidates) {
  const work = join(fixture.commandRoot, "work", String(++fixture.generation));
  await mkdir(work, { recursive: true });
  const candidates = {} as Candidates;
  for (const [name, source] of Object.entries(sources)) {
    const destination = join(work, name);
    await copyFile(source, destination);
    candidates[name as keyof Candidates] = destination;
  }
  await publishBuildReleaseSet(fixture.commandRoot, candidates, fixture.commandRuntimeId);
  return readReadyBuildReleaseSet(fixture.dataRoot, "fixture");
}

async function writeCommandRuntime(home: string): Promise<string> {
  const bootstrap = join(home, "data", "proj_cache", "bootstrap");
  const toolRoot = join(bootstrap, "fixture-tools");
  await mkdir(toolRoot, { recursive: true });
  const tools = [];
  for (const [name, version, file, content] of [
    ["bun", "1.2.15", "bun.exe", "bun"],
    ["pwsh", "7.6.4", "pwsh.exe", "pwsh"],
  ] as const) {
    const path = join(toolRoot, file);
    await writeFile(path, content);
    const bytes = await readFile(path);
    tools.push({
      name,
      version,
      path: `fixture-tools/${file}`,
      length: bytes.length,
      sha256: new Bun.CryptoHasher("sha256").update(bytes).digest("hex"),
    });
  }
  const identity = ["swawkit.proj-command-runtime/v1"];
  for (const tool of tools) {
    identity.push(tool.name, tool.version, tool.path, String(tool.length), tool.sha256);
  }
  const runtimeId = new Bun.CryptoHasher("sha256").update(identity.join("\n")).digest("hex");
  const release = join(bootstrap, "command-runtimes", "releases", runtimeId);
  await mkdir(release, { recursive: true });
  await writeFile(join(release, "manifest.json"), JSON.stringify({
    schema: "swawkit.proj-command-runtime/v1",
    runtimeId,
    tools,
  }));
  return runtimeId;
}

function systemExecutable(name: string): string {
  const root = process.env.SystemRoot;
  if (!root) throw new Error("SystemRoot is unavailable");
  return join(root, "System32", name);
}
