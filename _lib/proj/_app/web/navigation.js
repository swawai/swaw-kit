import { t } from "./i18n.js";
import { sameCommandIdentity } from "./command-identity.js";

const COMMAND_ROUTE_ROOT = "/commands";
const FACET_ID = /^[a-z][a-z0-9-]{0,31}$/;
const RESOURCE_SELECTOR = /^[a-z0-9][a-z0-9-]{0,127}$/;
const NORMAL_SEGMENT = /^[a-z][a-z0-9-]{0,63}$/;
const RESERVED_NAMESPACES = new Set(["system", "module"]);

function isCommandSegment(segment) {
  return NORMAL_SEGMENT.test(segment);
}

function addressSegments(command) {
  if (command.space === "system") {
    return command.address === "" ? [] : command.address.slice(1).split("/");
  }
  if (command.space === "module" && isCommandSegment(command.namespace)) {
    return [command.namespace, ...command.path];
  }
  throw new Error(t(
    `不支持的命令身份：${command.address}`,
    `Unsupported command identity: ${command.address}`,
  ));
}

export function commandPath(command) {
  const segments = addressSegments(command);
  const suffix = segments.length === 0
    ? ""
    : `/${segments.map(encodeURIComponent).join("/")}`;
  return `${COMMAND_ROUTE_ROOT}/${command.space}${suffix}`;
}

export function parseCommandPath(pathname) {
  if (pathname === "/" || pathname === COMMAND_ROUTE_ROOT || pathname === `${COMMAND_ROUTE_ROOT}/`) {
    return null;
  }
  const parts = pathname.split("/");
  if (parts.length < 3 || parts[0] !== "" || parts[1] !== "commands") {
    throw new Error(t("当前 URL 不是有效的命令地址。", "The current URL is not a valid command address."));
  }
  const space = parts[2];
  if (space !== "system" && space !== "module") {
    throw new Error(t(
      `URL 包含未知的命令空间：${space || "<empty>"}。`,
      `The URL contains an unknown command space: ${space || "<empty>"}.`,
    ));
  }
  let segments;
  try {
    segments = parts.slice(3).map((segment) => decodeURIComponent(segment));
  } catch {
    throw new Error(t("URL 包含无效的转义字符。", "The URL contains invalid escape characters."));
  }
  if (segments.some((segment) => !isCommandSegment(segment))) {
    throw new Error(t("URL 包含无效的命令路径段。", "The URL contains an invalid command path segment."));
  }
  if (space === "module" && segments.length === 0) {
    throw new Error(t(
      "URL 缺少模块 namespace。",
      "The URL is missing a module namespace.",
    ));
  }
  if (space === "system") {
    return {
      address: segments.length === 0 ? "" : `.${segments.join("/")}`,
      namespace: null,
      space,
    };
  }
  const [namespace, ...path] = segments;
  if (RESERVED_NAMESPACES.has(namespace)) {
    throw new Error(t("URL 包含保留的模块 namespace。", "The URL contains a reserved module namespace."));
  }
  return {
    address: path.length === 0 ? namespace : `${namespace}/${path.join("/")}`,
    namespace,
    space,
  };
}

export function commandAtPath(
  catalog,
  pathname,
  { allowMissing = false } = {},
) {
  const route = parseCommandPath(pathname);
  if (route === null) {
    return null;
  }
  const command = catalog.commandByAddress.get(route.address);
  if (!command || !sameCommandIdentity(command, route)) {
    if (allowMissing) {
      return null;
    }
    throw new Error(t(
      `URL 指向不存在的命令：${route.address || "<root>"}。`,
      `The URL points to a missing command: ${route.address || "<root>"}.`,
    ));
  }
  return command;
}

export function parseCommandSelection(search = "") {
  const params = new URLSearchParams(search);
  const allowed = new Set(["facet", "resource", "resource-facet"]);
  const unknown = [...params.keys()].find((name) => !allowed.has(name));
  if (unknown) {
    throw new Error(t(
      `URL 包含未知的 Resource 选择参数：${unknown}。`,
      `The URL contains an unknown Resource-selection parameter: ${unknown}.`,
    ));
  }
  const facets = params.getAll("facet");
  if (facets.length > 1) {
    throw new Error(t("URL 只能声明一个命令 Facet。", "The URL may declare only one command Facet."));
  }
  const facet = facets[0] ?? null;
  if (facet !== null && !FACET_ID.test(facet)) {
    throw new Error(t(
      `URL 包含无效的命令 Facet 标识：${facet || "<empty>"}。`,
      `The URL contains an invalid command-Facet identifier: ${facet || "<empty>"}.`,
    ));
  }
  const resources = params.getAll("resource");
  if (resources.length > 1) {
    throw new Error(t("URL 只能声明一个 Resource。", "The URL may declare only one Resource."));
  }
  const resource = resources[0] ?? null;
  if (resource !== null && !RESOURCE_SELECTOR.test(resource)) {
    throw new Error(t(
      `URL 包含无效的资源选择器：${resource || "<empty>"}。`,
      `The URL contains an invalid Resource selector: ${resource || "<empty>"}.`,
    ));
  }
  const resourceFacets = params.getAll("resource-facet");
  if (resourceFacets.length > 1) {
    throw new Error(t("URL 只能声明一个 Resource Facet。", "The URL may declare only one Resource Facet."));
  }
  const resourceFacet = resourceFacets[0] ?? null;
  if (resourceFacet !== null && !FACET_ID.test(resourceFacet)) {
    throw new Error(t(
      `URL 包含无效的 Resource Facet 标识：${resourceFacet || "<empty>"}。`,
      `The URL contains an invalid Resource-Facet identifier: ${resourceFacet || "<empty>"}.`,
    ));
  }
  if (resource !== null && facet === null) {
    throw new Error(t("Resource 深链必须声明其集合 Facet。", "A Resource deep link must declare its collection Facet."));
  }
  if (resourceFacet !== null && resource === null) {
    throw new Error(t("Resource Facet 缺少 Resource。", "A Resource Facet requires a Resource."));
  }
  return { facet, resource, resourceFacet };
}

export function parseCommandFacet(search = "") {
  return parseCommandSelection(search).facet;
}

export async function restoreCommandSelection({
  collectionFacet,
  loadResourceList,
  ownerAddress,
  selectOwner,
  selectResource,
  resourceFacet,
  resourceSelector,
}) {
  const ownerSelected = selectOwner();
  if (!resourceSelector || ownerSelected === false) {
    return ownerSelected !== false;
  }
  const collection = await loadResourceList(ownerAddress, collectionFacet);
  if (!collection) {
    return null;
  }
  return selectResource(ownerAddress, collectionFacet, resourceSelector, {
    facet: resourceFacet,
  });
}

export function updateCommandPath(
  history,
  location,
  command,
  {
    defaultFacet = null,
    defaultResourceFacet = null,
    facet = null,
    mode = "push",
    resource = null,
    resourceFacet = null,
  } = {},
) {
  if (mode === "none") {
    return;
  }
  const params = new URLSearchParams();
  if (facet && (resource || facet !== defaultFacet)) {
    params.set("facet", facet);
  }
  if (resource) {
    params.set("resource", resource);
  }
  if (resourceFacet && resourceFacet !== defaultResourceFacet) {
    params.set("resource-facet", resourceFacet);
  }
  const query = params.size > 0 ? `?${params}` : "";
  const path = `${commandPath(command)}${query}`;
  const current = `${location.pathname}${location.search ?? ""}`;
  if (mode === "push" && current === path) {
    return;
  }
  if (mode === "replace") {
    history.replaceState(null, "", path);
  } else {
    history.pushState(null, "", path);
  }
}
