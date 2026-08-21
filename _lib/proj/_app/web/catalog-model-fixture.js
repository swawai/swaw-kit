export const protocol = "swawkit.command-catalog/v24";

export function node(address, overrides = {}) {
  const space = overrides.space ?? (address.startsWith(".") || address === "" ? "system" : "module");
  const namespace = space === "module"
    ? overrides.namespace ?? address.split("/")[0]
    : null;
  const path = space === "system"
    ? address === "" ? [] : address.slice(1).split("/")
    : space === "module"
      ? address === namespace ? [] : address.slice(namespace.length + 1).split("/")
      : [];
  const command = {
    address,
    space,
    namespace,
    path,
    parent: "",
    aliasOf: null,
    runnable: false,
    entry: null,
    adapter: null,
    handler: null,
    product: null,
    help: null,
    resourceKinds: [],
    facets: [],
    diagnostic: null,
    ...overrides,
  };
  return command;
}

export function payload(commands, overrides = {}) {
  return {
    protocol,
    entryName: "swawkit",
    language: "zh-CN",
    commands,
    ...overrides,
  };
}
