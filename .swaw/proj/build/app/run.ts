import { lstat, stat } from "node:fs/promises";
import { isAbsolute, join, resolve } from "node:path";
import {
  controlledPath,
  ensureControlledDirectory,
  publishBuildReleaseSet,
  RUNTIME_ARTIFACT_NAMES,
} from "../_lib/release-set.ts";
import { acquireExclusiveFileLock } from "../_lib/windows-filesystem.ts";

if (Bun.argv.length !== 2) {
  throw new Error("project/proj/build/app does not accept dynamic arguments.");
}

const commandDataRoot = requiredAbsolute("SWAWKIT_PROJ_CORE_COMMAND_DATA_ROOT");
const swawkitHome = requiredAbsolute("SWAWKIT_HOME");
const cargoHome = requiredAbsolute("CARGO_HOME");
const appRoot = resolve(swawkitHome, "_lib", "proj", "_app");
const moduleRoot = resolve(swawkitHome, "_lib", "proj", "system", "module");
const appManifest = join(appRoot, "Cargo.toml");
const moduleManifest = join(moduleRoot, "Cargo.toml");
const cargo = join(cargoHome, "bin", "cargo.exe");
await regularFile(appManifest, "application Cargo manifest");
await regularFile(moduleManifest, "Module Cargo manifest");
await executableFile(cargo, "managed Cargo executable");

const locks = await ensureControlledDirectory(commandDataRoot, ["locks"], "build locks");
const appWork = await ensureControlledDirectory(
  commandDataRoot,
  ["work", "cargo-app"],
  "application Cargo work",
);
const moduleWork = await ensureControlledDirectory(
  commandDataRoot,
  ["work", "cargo-module"],
  "Module Cargo work",
);
using lock = await acquireExclusiveFileLock(join(locks, "build.lock"), 30 * 60 * 1000);

await cargoBuild("application", appRoot, appManifest, appWork);
await cargoBuild("Module", moduleRoot, moduleManifest, moduleWork);

const appRelease = await ensureControlledDirectory(
  appWork,
  ["release"],
  "application Cargo release output",
);
const moduleRelease = await ensureControlledDirectory(
  moduleWork,
  ["release"],
  "Module Cargo release output",
);
const candidates: Record<typeof RUNTIME_ARTIFACT_NAMES[number], string> = {
  "swawkit-proj.exe": controlledPath(
    commandDataRoot,
    join(appRelease, "swawkit-proj.exe"),
    "Core build candidate",
  ),
  "swawkit-proj-host.exe": controlledPath(
    commandDataRoot,
    join(appRelease, "swawkit-proj-host.exe"),
    "Host build candidate",
  ),
  "swawkit-proj-module.exe": controlledPath(
    commandDataRoot,
    join(moduleRelease, "swawkit-proj-module.exe"),
    "Module build candidate",
  ),
  "swawkit-proj-toolchain.exe": controlledPath(
    commandDataRoot,
    join(appRelease, "swawkit-proj-toolchain.exe"),
    "Toolchain build candidate",
  ),
};
for (const [name, path] of Object.entries(candidates)) {
  const metadata = await lstat(path);
  if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.size <= 0) {
    throw new Error(`Cargo reported success but ${name} is missing or invalid: ${path}`);
  }
  console.log(`[BUILT] ${path} (${metadata.size} bytes)`);
}
const id = await publishBuildReleaseSet(commandDataRoot, candidates);
console.log(`[READY] project/proj/build/app release ${id}`);

async function cargoBuild(
  label: string,
  root: string,
  manifest: string,
  target: string,
): Promise<void> {
  const build = Bun.spawn([
    cargo,
    "build",
    "--locked",
    "--release",
    "--manifest-path",
    manifest,
    "--target-dir",
    target,
  ], {
    cwd: root,
    stdin: "inherit",
    stdout: "inherit",
    stderr: "inherit",
  });
  const exitCode = await build.exited;
  if (exitCode !== 0) {
    throw new Error(`${label} Cargo build failed with exit code ${exitCode}.`);
  }
}

function requiredAbsolute(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`required environment variable is missing: ${name}`);
  if (!isAbsolute(value)) throw new Error(`${name} must be absolute: ${value}`);
  return resolve(value);
}

async function regularFile(path: string, label: string): Promise<void> {
  const metadata = await lstat(path);
  if (!metadata.isFile() || metadata.isSymbolicLink()) {
    throw new Error(`${label} is not a regular file: ${path}`);
  }
}

async function executableFile(path: string, label: string): Promise<void> {
  const metadata = await stat(path);
  if (!metadata.isFile() || metadata.size <= 0) {
    throw new Error(`${label} is not a file: ${path}`);
  }
}
