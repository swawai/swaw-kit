import { lstat, readFile } from "node:fs/promises";
import { isAbsolute, join, relative, resolve, sep } from "node:path";

const ENVIRONMENT_SCHEMA = "swawkit.proj-bootstrap-environment/v1";
const MAX_TOOL_BYTES = 512 * 1024 * 1024;

type ToolName = "cargo" | "rustc" | "compiler" | "linker";
type ToolRecord = { path: string; length: number; sha256: string };

export type BootstrapBuildEnvironment = {
  environment: Record<string, string>;
  tools: Record<ToolName, string>;
};

export async function loadBootstrapBuildEnvironment(
  projHome: string,
): Promise<BootstrapBuildEnvironment> {
  const bootstrapRoot = resolve(projHome, "data", "proj_cache", "bootstrap");
  const toolchainRoot = join(bootstrapRoot, "toolchains");
  const contractPath = join(projHome, "_lib", "proj", "bootstrap.json");
  const environmentPath = join(bootstrapRoot, "environment.json");
  const [contractBytes, documentBytes] = await Promise.all([
    readFile(contractPath),
    readFile(environmentPath),
  ]);
  const contract = parseObject(contractBytes, "Bootstrap contract");
  const document = parseObject(documentBytes, "Bootstrap builder environment");
  if (
    document.schema !== ENVIRONMENT_SCHEMA
    || JSON.stringify(document.contract) !== JSON.stringify(contract)
    || document.contractRevision !== `sha256-${sha256(contractBytes)}`
    || !isStringMap(document.variables)
    || !isStringArray(document.pathPrefixes)
    || !isObject(document.tools)
  ) {
    throw new Error(`Bootstrap builder environment is invalid: ${environmentPath}`);
  }

  const tools = {} as Record<ToolName, string>;
  for (const [name, executable] of [
    ["cargo", "cargo.exe"],
    ["rustc", "rustc.exe"],
    ["compiler", "cl.exe"],
    ["linker", "link.exe"],
  ] as const) {
    const record = document.tools[name];
    if (!isToolRecord(record)) {
      throw new Error(`Bootstrap ${name} record is invalid: ${environmentPath}`);
    }
    tools[name] = await validateTool(toolchainRoot, record, executable);
  }

  const environment = { ...process.env } as Record<string, string>;
  for (const [name, value] of Object.entries(document.variables)) {
    if (value === null) delete environment[name];
    else environment[name] = value;
  }
  const inheritedPath = process.env.PATH ?? "";
  environment.PATH = [...document.pathPrefixes, inheritedPath]
    .filter((value) => value.length > 0)
    .join(";");
  return { environment, tools };
}

async function validateTool(
  toolchainRoot: string,
  record: ToolRecord,
  executable: string,
): Promise<string> {
  if (!isAbsolute(record.path) || resolve(record.path) !== record.path) {
    throw new Error(`Bootstrap ${executable} path is not canonical: ${record.path}`);
  }
  const child = relative(toolchainRoot, record.path);
  if (child === "" || child === ".." || child.startsWith(`..${sep}`) || isAbsolute(child)) {
    throw new Error(`Bootstrap ${executable} escaped the toolchain root: ${record.path}`);
  }
  if (record.path.split(/[\\/]/).at(-1) !== executable) {
    throw new Error(`Bootstrap tool has an unexpected name: ${record.path}`);
  }
  const metadata = await lstat(record.path);
  if (
    !metadata.isFile()
    || metadata.isSymbolicLink()
    || metadata.size !== record.length
    || metadata.size <= 0
    || metadata.size > MAX_TOOL_BYTES
  ) {
    throw new Error(`Bootstrap ${executable} is invalid: ${record.path}`);
  }
  const bytes = await readFile(record.path);
  if (sha256(bytes) !== record.sha256) {
    throw new Error(`Bootstrap ${executable} digest is invalid: ${record.path}`);
  }
  return record.path;
}

function parseObject(bytes: Uint8Array, label: string): Record<string, any> {
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder().decode(bytes));
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error}`);
  }
  if (!isObject(value)) throw new Error(`${label} must be an object.`);
  return value;
}

function isObject(value: unknown): value is Record<string, any> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function isStringMap(value: unknown): value is Record<string, string | null> {
  return isObject(value)
    && Object.entries(value).every(([name, item]) => name.length > 0 && (item === null || typeof item === "string"));
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((item) => typeof item === "string" && isAbsolute(item));
}

function isToolRecord(value: unknown): value is ToolRecord {
  return isObject(value)
    && Object.keys(value).sort().join("\n") === ["length", "path", "sha256"].join("\n")
    && typeof value.path === "string"
    && Number.isSafeInteger(value.length)
    && value.length > 0
    && value.length <= MAX_TOOL_BYTES
    && typeof value.sha256 === "string"
    && /^[a-f0-9]{64}$/.test(value.sha256);
}

function sha256(bytes: Uint8Array): string {
  return new Bun.CryptoHasher("sha256").update(bytes).digest("hex");
}
