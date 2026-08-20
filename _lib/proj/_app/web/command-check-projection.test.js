import { describe, expect, test } from "bun:test";

import { COMMAND_CHECK_PROTOCOL } from "./command-check-projection-model.js";
import { createCommandCheckProjectionRenderer } from "./command-check-projection.js";

function element(hidden = false) {
  return {
    children: [],
    className: "",
    dataset: {},
    hidden,
    textContent: "",
    append(...children) { this.children.push(...children); },
    replaceChildren(...children) { this.children = children; },
  };
}

function elements() {
  return {
    commandCheckDependencies: element(),
    commandCheckDiagnostic: element(true),
    commandCheckMeta: element(),
    commandCheckPane: element(true),
    commandCheckState: element(),
    commandCheckTitle: element(),
  };
}

function dependency(overrides = {}) {
  return {
    provider: ".provider",
    export: "fixture",
    ready: false,
    status: "not-ready",
    message: "Build the provider first.",
    checker: null,
    dependencies: [],
    ...overrides,
  };
}

describe("Command check projection renderer", () => {
  test("renders execution readiness and recursive dependencies", () => {
    const nodes = elements();
    const renderer = createCommandCheckProjectionRenderer(nodes, {
      document: { createElement: () => element() },
    });

    renderer.render({ address: ".tool", space: "system" }, {
      protocol: COMMAND_CHECK_PROTOCOL,
      command: {
        address: ".tool",
        space: "system",
        namespace: null,
        runnable: true,
        adapter: "pwsh",
        diagnostic: null,
      },
      dependencies: [dependency({
        dependencies: [dependency({ provider: ".transitive" })],
      })],
      ready: false,
    });

    expect(renderer.protocol).toBe(COMMAND_CHECK_PROTOCOL);
    expect(nodes.commandCheckPane.hidden).toBeFalse();
    expect(nodes.commandCheckTitle.textContent).toBe(".tool");
    expect(nodes.commandCheckState.textContent).toBe("执行受阻");
    expect(nodes.commandCheckState.dataset.state).toBe("blocked");
    expect(nodes.commandCheckDependencies.children[0].dataset.state).toBe("blocked");
    expect(nodes.commandCheckDependencies.children[0].children[0].children[1].textContent)
      .toBe(".provider#fixture");
    expect(nodes.commandCheckDependencies.children[0].children.at(-1).children).toHaveLength(1);
  });

  test("renders a checker as a relative command URL with explicit arguments", () => {
    const nodes = elements();
    const renderer = createCommandCheckProjectionRenderer(nodes, {
      document: { createElement: () => element() },
    });
    renderer.render({ address: ".tool", space: "system" }, {
      protocol: COMMAND_CHECK_PROTOCOL,
      command: {
        address: ".tool",
        space: "system",
        namespace: null,
        runnable: true,
        adapter: "pwsh",
        diagnostic: null,
      },
      dependencies: [dependency({
        checker: {
          address: ".dev/setup/check",
          arguments: ["environment"],
          namespace: null,
          space: "system",
        },
      })],
      ready: false,
    });

    const action = nodes.commandCheckDependencies.children[0].children[2];
    expect(action.textContent).toBe("检查：");
    expect(action.children[0].href).toBe("/commands/system/dev/setup/check");
    expect(action.children[0].textContent).toBe("/commands/system/dev/setup/check");
    expect(action.children[1].textContent).toBe(" environment");
  });

  test("renders a module provider checker with its namespace path", () => {
    const nodes = elements();
    const renderer = createCommandCheckProjectionRenderer(nodes, {
      document: { createElement: () => element() },
    });
    renderer.render({
      address: "project/consumer",
      namespace: "project",
      space: "module",
    }, {
      protocol: COMMAND_CHECK_PROTOCOL,
      command: {
        address: "project/consumer",
        space: "module",
        namespace: "project",
        runnable: true,
        adapter: "pwsh",
        diagnostic: null,
      },
      dependencies: [dependency({
        provider: "project/provider",
        checker: {
          address: "project/provider/check",
          arguments: ["fixture"],
          namespace: "project",
          space: "module",
        },
      })],
      ready: false,
    });

    const link = nodes.commandCheckDependencies.children[0].children[2].children[0];
    expect(link.href).toBe("/commands/module/project/provider/check");
  });

  test("renders a dependency-free command as ready to run", () => {
    const nodes = elements();
    const renderer = createCommandCheckProjectionRenderer(nodes, {
      document: { createElement: () => element() },
    });
    renderer.render({ address: ".tool", space: "system" }, {
      protocol: COMMAND_CHECK_PROTOCOL,
      command: {
        address: ".tool",
        space: "system",
        namespace: null,
        runnable: true,
        adapter: "pwsh",
        diagnostic: null,
      },
      dependencies: [],
      ready: true,
    });

    expect(nodes.commandCheckState.textContent).toBe("执行就绪");
    expect(nodes.commandCheckState.dataset.state).toBe("ready");
    expect(nodes.commandCheckDependencies.children[0].textContent).toBe("无执行依赖");
  });
});
