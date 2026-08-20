import {
  normalizeCommandIdentity,
  sameCommandIdentity,
} from "./command-identity.js";

export const COMMAND_CHECK_PROTOCOL = "swawkit.command-check/v3";

const MAX_ITEMS = 512;

function invalid(message) {
  return new Error(`命令检查协议无效：${message}`);
}

function object(value, field) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw invalid(`${field} 必须是对象。`);
  }
  return value;
}

function exactKeys(value, field, expected) {
  const actual = Object.keys(value).sort();
  const canonical = [...expected].sort();
  if (actual.join("\n") !== canonical.join("\n")) {
    throw invalid(`${field} 字段必须精确为 ${canonical.join("、")}。`);
  }
}

function string(value, field) {
  if (typeof value !== "string" || value.length === 0) {
    throw invalid(`${field} 必须是非空字符串。`);
  }
  return value;
}

function nullableString(value, field) {
  return value === null ? null : string(value, field);
}

function boolean(value, field) {
  if (typeof value !== "boolean") {
    throw invalid(`${field} 必须是布尔值。`);
  }
  return value;
}

function array(value, field) {
  if (!Array.isArray(value)) {
    throw invalid(`${field} 必须是数组。`);
  }
  return value;
}

function checker(value, field) {
  if (value === null) {
    return null;
  }
  const item = object(value, field);
  exactKeys(item, field, ["address", "arguments", "namespace", "space"]);
  const identity = normalizeCommandIdentity(item, field, invalid);
  const arguments_ = array(item.arguments, `${field}.arguments`);
  if (
    arguments_.length > 32
    || arguments_.some((argument) => typeof argument !== "string" || argument.length > 4096)
  ) {
    throw invalid(`${field}.arguments 必须是最多 32 项、每项最多 4096 字符的字符串数组。`);
  }
  return {
    address: identity.address,
    arguments: [...arguments_],
    namespace: identity.namespace,
    path: identity.path,
    space: identity.space,
  };
}

function dependency(value, field, budget, depth = 0) {
  if (depth > 32) {
    throw invalid("依赖层级过深。");
  }
  budget.count += 1;
  if (budget.count > MAX_ITEMS) {
    throw invalid(`检查结果最多包含 ${MAX_ITEMS} 个依赖。`);
  }
  const item = object(value, field);
  exactKeys(item, field, [
    "checker",
    "dependencies",
    "export",
    "message",
    "provider",
    "ready",
    "status",
  ]);
  const dependencies = array(item.dependencies, `${field}.dependencies`).map((child, index) => (
    dependency(child, `${field}.dependencies[${index}]`, budget, depth + 1)
  ));
  const ready = boolean(item.ready, `${field}.ready`);
  const status = string(item.status, `${field}.status`);
  const expectedReady = status === "ready"
    && dependencies.every((child) => child.ready);
  if (ready !== expectedReady) {
    throw invalid(`${field}.ready 与 status 及子依赖状态不一致。`);
  }
  return {
    checker: checker(item.checker, `${field}.checker`),
    dependencies,
    export: string(item.export, `${field}.export`),
    message: nullableString(item.message, `${field}.message`),
    provider: string(item.provider, `${field}.provider`),
    ready,
    status,
  };
}

export function createCommandCheckProjection(value, subject) {
  const document_ = object(value, "check");
  exactKeys(document_, "check", ["command", "dependencies", "protocol", "ready"]);
  if (document_.protocol !== COMMAND_CHECK_PROTOCOL) {
    throw invalid(`protocol 必须是 ${COMMAND_CHECK_PROTOCOL}。`);
  }
  const command = object(document_.command, "command");
  exactKeys(command, "command", [
    "adapter",
    "address",
    "diagnostic",
    "namespace",
    "runnable",
    "space",
  ]);
  const identity = normalizeCommandIdentity(command, "command", invalid);
  if (!sameCommandIdentity(identity, subject)) {
    throw invalid("command identity 与选中的命令不一致。");
  }
  const normalizedCommand = {
    adapter: nullableString(command.adapter, "command.adapter"),
    address: identity.address,
    diagnostic: nullableString(command.diagnostic, "command.diagnostic"),
    namespace: identity.namespace,
    runnable: boolean(command.runnable, "command.runnable"),
    space: identity.space,
  };
  const budget = { count: 0 };
  const dependencies = array(document_.dependencies, "dependencies").map((item, index) => (
    dependency(item, `dependencies[${index}]`, budget)
  ));
  const ready = boolean(document_.ready, "ready");
  const expectedReady = normalizedCommand.runnable
    && dependencies.every((item) => item.ready);
  if (ready !== expectedReady) {
    throw invalid("ready 与命令及依赖状态不一致。");
  }
  return {
    command: normalizedCommand,
    dependencies,
    protocol: COMMAND_CHECK_PROTOCOL,
    ready,
  };
}
