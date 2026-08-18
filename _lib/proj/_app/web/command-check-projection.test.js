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
    contract: "fixture/v1",
    ready: false,
    status: "not-ready",
    message: "Build the provider first.",
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
    expect(nodes.commandCheckDependencies.children[0].children.at(-1).children).toHaveLength(1);
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
