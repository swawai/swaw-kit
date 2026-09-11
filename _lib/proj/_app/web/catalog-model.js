import { t } from "./i18n.js";
import { normalizeFacets as normalizeFacetDocuments } from "./facet-model.js";
import { normalizeResourceKinds } from "./resource-kind-model.js";
import { normalizeCommandIdentity } from "./command-identity.js";
import { canonicalFacetRoute, commandResourceRoute } from "./resource-route.js";

const CATALOG_PROTOCOL = "swawkit.command-catalog/v24";
const RUNTIME_OWNERS = {
  dev: new Set([
    ".dev/settings",
    ".dev/setup",
    ".dev/setup/check",
    ".dev/status",
    ".dev/bun/mode",
    ".dev/bun/sha256",
    ".dev/bun/version",
    ".dev/pwsh/mode",
    ".dev/pwsh/sha256",
    ".dev/pwsh/version",
    ".dev/msvc/mode",
    ".dev/msvc/channel",
    ".dev/rust/mode",
    ".dev/rust/toolchain",
  ]),
  module: new Set([".module/instantiate", ".module/status"]),
};

function contractError(message) {
  return new Error(`${t("Catalog 协议无效", "Invalid Catalog protocol")}: ${message}`);
}

function requireObject(value, field) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw contractError(`${field} 必须是对象。`);
  }
  return value;
}

function requireString(value, field, { allowEmpty = true } = {}) {
  if (
    typeof value !== "string"
    || (!allowEmpty && value.trim().length === 0)
  ) {
    const expectation = allowEmpty ? "字符串" : "非空字符串";
    throw contractError(`${field} 必须是${expectation}。`);
  }
  return value;
}

function nullableString(value, field, { allowEmpty = false } = {}) {
  return value === null
    ? null
    : requireString(value, field, { allowEmpty });
}

function normalizeHelp(value, index) {
  if (value === null) {
    return null;
  }

  const help = requireObject(value, `commands[${index}].help`);
  return {
    summary: requireString(help.summary, `commands[${index}].help.summary`),
    text: requireString(help.text, `commands[${index}].help.text`),
  };
}

function normalizeCommand(value, index) {
  const command = requireObject(value, `commands[${index}]`);
  const field = (name) => `commands[${index}].${name}`;
  const identity = normalizeCommandIdentity(
    command,
    `commands[${index}]`,
    contractError,
    { requirePath: true },
  );
  const { address, namespace, path, space } = identity;
  if (typeof command.runnable !== "boolean") {
    throw contractError(`${field("runnable")} 必须是布尔值。`);
  }

  const entry = nullableString(command.entry, field("entry"));
  const adapter = nullableString(command.adapter, field("adapter"));
  const handler = nullableString(command.handler, field("handler"));
  const product = nullableString(command.product, field("product"));
  const issue = nullableString(command.diagnostic, field("diagnostic"));
  if (command.runnable !== (entry !== null)) {
    throw contractError(`${field("runnable")} 必须与 entry 是否存在一致。`);
  }
  if ((entry === null) !== (adapter === null)) {
    throw contractError(`${field("adapter")} 必须与 entry 同时存在或同时为空。`);
  }
  const handlerAdapter = adapter === "core";
  if (handlerAdapter !== (handler !== null)) {
    throw contractError(
      `${field("handler")} 必须且只能由 core adapter 声明。`,
    );
  }
  if ((adapter === "runtime") !== (product !== null)) {
    throw contractError(
      `${field("product")} must be declared if and only if adapter is runtime.`,
    );
  }

  const help = normalizeHelp(command.help, index);
  if (
    adapter === "runtime"
    && (space !== "system" || !RUNTIME_OWNERS[product]?.has(address))
  ) {
    throw contractError(
      `${field("product")} runtime product is not valid for this System command.`,
    );
  }
  const facets = normalizeFacetDocuments(
    command.facets,
    `commands[${index}].facets`,
    contractError,
  );
  const resourceKinds = normalizeResourceKinds(
    command.resourceKinds,
    `commands[${index}].resourceKinds`,
    contractError,
  );
  return {
    facets,
    address,
    adapter: adapter ?? "",
    aliasOf: nullableString(command.aliasOf, field("aliasOf")),
    entry: entry ?? "",
    help: help?.text ?? "",
    handler: handler ?? "",
    issue: issue ?? "",
    namespace,
    parent: nullableString(command.parent, field("parent"), {
      allowEmpty: true,
    }),
    path,
    product: product ?? "",
    runnable: command.runnable,
    space,
    resourceKinds,
    summary: help?.summary ?? "",
  };
}

export function createCatalog(document) {
  const payload = requireObject(document, "Catalog");
  if (payload.protocol !== CATALOG_PROTOCOL) {
    throw contractError(`protocol 必须是 ${CATALOG_PROTOCOL}。`);
  }
  const entryName = requireString(payload.entryName, "entryName", {
    allowEmpty: false,
  });
  const language = requireString(payload.language, "language", {
    allowEmpty: false,
  });
  if (!new Set(["zh-CN", "en"]).has(language)) {
    throw contractError(t("language 只能是 zh-CN 或 en。", "language must be zh-CN or en."));
  }
  if (!Array.isArray(payload.commands)) {
    throw contractError("commands 必须是数组。");
  }

  const commandByAddress = new Map();
  const resourceKindBySource = new Map();
  const seenAddresses = new Set();
  for (const [index, rawCommand] of payload.commands.entries()) {
    const command = normalizeCommand(rawCommand, index);
    if (seenAddresses.has(command.address)) {
      throw contractError(`命令地址 ${command.address || "<root>"} 重复。`);
    }
    seenAddresses.add(command.address);

    if (command.address && !command.aliasOf) {
      commandByAddress.set(command.address, command);
    }
    for (const resourceKind of command.resourceKinds) {
      const source = canonicalFacetRoute(resourceKind.source);
      if (resourceKindBySource.has(source)) {
        throw contractError(`Resource Kind source ${source} is declared more than once.`);
      }
      resourceKindBySource.set(source, { command, resourceKind });
    }
  }

  for (const command of commandByAddress.values()) {
    for (const facet of command.facets) {
      if (
        facet.resourceKind !== null
        && !resourceKindBySource.has(canonicalFacetRoute(facet.resourceKind.source))
      ) {
        throw contractError(
          `${command.address}.facets.${facet.id} references an unavailable Resource Kind.`,
        );
      }
      if (facet.resolver?.type !== "command") {
        continue;
      }
      const target = commandByAddress.get(facet.resolver.address);
      if (!target) {
        throw contractError(
          `${command.address}.facets.${facet.id} 引用了不存在的命令。`,
        );
      }
      const controlEdit = facet.renderer === "edit"
        && target.space === "system"
        && target.handler === "entry.config.set";
      if (
        !target.runnable
        || (target.space === "system" && target.path[0] === "entry" && !controlEdit)
        || target.aliasOf
      ) {
        throw contractError(
          `${command.address}.facets.${facet.id} 不是可由 Web 执行的精确命令。`,
        );
      }
    }
    for (const resourceKind of command.resourceKinds) {
      for (const facet of resourceKind.facets) {
        const target = commandByAddress.get(facet.resolver.address);
        if (
          !target
          || !target.runnable
          || (target.space === "system" && ["entry", "runtime"].includes(target.path[0]))
          || target.aliasOf
        ) {
          throw contractError(
            `${command.address}.resourceKinds.${resourceKind.kind}.${facet.id} has an invalid resolver target.`,
          );
        }
      }
    }
  }

  const commandByResourceRoute = new Map();
  for (const command of commandByAddress.values()) {
    const route = commandResourceRoute(command);
    if (commandByResourceRoute.has(route)) {
      throw contractError(`Resource Route ${route} is declared more than once.`);
    }
    commandByResourceRoute.set(route, command);
  }

  const childrenByParent = new Map();
  const roots = [];
  for (const command of commandByAddress.values()) {
    if (
      command.parent
      && command.parent !== command.address
      && commandByAddress.has(command.parent)
    ) {
      const siblings = childrenByParent.get(command.parent) ?? [];
      siblings.push(command);
      childrenByParent.set(command.parent, siblings);
    } else {
      roots.push(command);
    }
  }

  return {
    childrenByParent,
    commandByAddress,
    commandByResourceRoute,
    commands: [...commandByAddress.values()],
    entryName,
    language,
    collator: new Intl.Collator(language, {
      numeric: true,
      sensitivity: "base",
    }),
    protocol: CATALOG_PROTOCOL,
    roots,
    resourceKindBySource,
  };
}

export function childrenOf(catalog, address) {
  return catalog.childrenByParent.get(address) ?? [];
}

export function hasChildren(catalog, command) {
  return childrenOf(catalog, command.address).length > 0;
}

export function isGroup(catalog, command) {
  return hasChildren(catalog, command);
}

export function sortCommands(catalog, commands) {
  return [...commands].sort((left, right) => (
    catalog.collator.compare(left.address, right.address)
  ));
}

export function leafName(address) {
  const parts = address.split(/[./\\]+/).filter(Boolean);
  return parts.at(-1) || address;
}

export function cliInvocation(catalog, command) {
  return `${catalog.entryName} ${command.address}`;
}
