import { describe, expect, test } from "bun:test";

import {
  availableCommand,
  captureColumnScrollOffsets,
  childrenColumnWidth,
  choiceColumnModels,
  commandHasChoices,
  commandMenuExpanded,
  createExplorerView,
  restoreColumnScrollOffsets,
} from "./explorer.js";

function domNode(tagName = "") {
  return {
    attributes: new Map(),
    children: [],
    className: "",
    dataset: {},
    disabled: false,
    scrollTop: 0,
    tagName,
    addEventListener() {},
    append(...children) { this.children.push(...children); },
    getAttribute(name) { return this.attributes.get(name) ?? null; },
    querySelectorAll(selector) {
      const className = selector.startsWith(".") ? selector.slice(1) : null;
      const matches = [];
      const visit = (node) => {
        if (className && node.className?.split(/\s+/).includes(className)) {
          matches.push(node);
        }
        node.children?.forEach(visit);
      };
      this.children.forEach(visit);
      return matches;
    },
    replaceChildren(...children) { this.children = children; },
    setAttribute(name, value) { this.attributes.set(name, String(value)); },
  };
}

function findByClass(root, className) {
  if (root.className?.split(/\s+/).includes(className)) {
    return root;
  }
  return root.children?.map((child) => findByClass(child, className)).find(Boolean) ?? null;
}

describe("Explorer command-space behavior", () => {
  test("resolves every Catalog command without a global setup gate", () => {
    const system = { address: ".entry", space: "system" };
    const module = { address: "project", namespace: "project", space: "module" };
    const catalog = {
      commandByAddress: new Map([
        [system.address, system],
        [module.address, module],
      ]),
    };

    expect(availableCommand(catalog, module.address)).toBe(module);
    expect(availableCommand(catalog, system.address)).toBe(system);
    expect(availableCommand(catalog, "missing")).toBeNull();
  });

  test("keeps menu expansion independent from the selected command path", () => {
    expect(commandMenuExpanded(".dev/rust", ".dev")).toBe(false);
    expect(commandMenuExpanded(".dev/rust", ".dev/rust")).toBe(true);
    expect(commandMenuExpanded(null, ".dev/rust")).toBe(false);
  });

  test("uses the parent command's declared child column width", () => {
    expect(childrenColumnWidth({ childrenColumnWidth: "wide" })).toBe("wide");
    expect(childrenColumnWidth({})).toBe("normal");
  });

  test("reveals choices only through declared Facets", () => {
    const parent = { address: "proj" };
    const leaf = { address: "project/build" };
    const catalog = {
      childrenByParent: new Map([[parent.address, [leaf]]]),
    };

    expect(commandHasChoices(catalog, parent, [{ name: "children" }])).toBe(true);
    expect(commandHasChoices(catalog, leaf, [{ name: "overview" }])).toBe(true);
    expect(commandHasChoices(catalog, leaf, [])).toBe(false);
  });

  test("renders an enabled menu toggle for a command with Facets", () => {
    const previous = {
      document: globalThis.document,
      requestAnimationFrame: globalThis.requestAnimationFrame,
      window: globalThis.window,
    };
    const present = {
      document: "document" in globalThis,
      requestAnimationFrame: "requestAnimationFrame" in globalThis,
      window: "window" in globalThis,
    };
    const columns = domNode("main");
    const command = {
      address: ".help",
      parent: "",
      runnable: true,
      space: "system",
      summary: "Help",
    };
    const facet = {
      icon: "?",
      kind: "projection",
      label: "Overview",
      name: "overview",
      selected: true,
      summary: "Show help",
    };

    globalThis.document = {
      addEventListener() {},
      createElement: (tagName) => domNode(tagName),
    };
    globalThis.window = { addEventListener() {} };
    globalThis.requestAnimationFrame = () => 0;
    try {
      const view = createExplorerView({
        columns,
        detailPanel: domNode("aside"),
        getCommandFacets: () => [facet],
        onSelectCommand() {},
      });
      const catalog = {
        childrenByParent: new Map(),
        collator: new Intl.Collator("en"),
        commandByAddress: new Map([[command.address, command]]),
        roots: [command],
      };

      expect(() => view.setCatalog(catalog)).not.toThrow();
      const toggle = findByClass(columns, "command-menu-toggle");
      expect(toggle).not.toBeNull();
      expect(toggle.disabled).toBe(false);
      expect(toggle.getAttribute("disabled")).toBeNull();
    } finally {
      for (const name of Object.keys(previous)) {
        if (present[name]) {
          globalThis[name] = previous[name];
        } else {
          delete globalThis[name];
        }
      }
    }
  });

  test("keeps ancestor child columns but obeys the terminal command view", () => {
    const entry = { address: ".dev" };
    const env = { address: ".dev/rust" };
    const bun = { address: ".dev/rust/cargo" };
    const catalog = {
      commandByAddress: new Map([
        [entry.address, entry],
        [env.address, env],
        [bun.address, bun],
      ]),
      childrenByParent: new Map([
        [entry.address, [env]],
        [env.address, [bun]],
      ]),
    };
    const overviewModels = choiceColumnModels(
      catalog,
      [entry.address, env.address, bun.address],
      (command) => command.address === bun.address
        ? [{ name: "overview", selected: true }]
        : [{
          kind: "collection",
          name: "children",
          resolver: { relation: "children", type: "catalog" },
          selected: false,
        }],
    );

    expect(overviewModels.map(({ command }) => command.address)).toEqual([
      entry.address,
      env.address,
    ]);
    expect(overviewModels.map(({ mode }) => mode)).toEqual([
      "children",
      "children",
    ]);

    catalog.childrenByParent.set(bun.address, [{
      address: `${bun.address}/mode`,
    }]);
    const childrenModels = choiceColumnModels(
      catalog,
      [entry.address, env.address, bun.address],
      (command) => [{
        kind: "collection",
        name: "children",
        resolver: { relation: "children", type: "catalog" },
        selected: command.address === bun.address,
      }],
    );
    expect(childrenModels.map(({ command }) => command.address)).toEqual([
      entry.address,
      env.address,
      bun.address,
    ]);
  });

  test("keeps the collection column visible for a selected Subject", () => {
    const context = { address: ".context" };
    const catalog = {
      commandByAddress: new Map([[context.address, context]]),
      childrenByParent: new Map(),
    };
    const models = choiceColumnModels(
      catalog,
      [context.address],
      () => [{ name: "overview", selected: true }],
      { owner: context.address, facet: "contexts" },
    );
    expect(models.map(({ command }) => command.address)).toEqual([context.address]);
    expect(models.map(({ mode }) => mode)).toEqual(["contexts"]);
  });

  test("treats structural, Subject, and projection Facets as mutually exclusive", () => {
    const context = { address: ".context" };
    const list = { address: ".context/list" };
    const catalog = {
      commandByAddress: new Map([[context.address, context]]),
      childrenByParent: new Map([[context.address, [list]]]),
    };
    const modelsFor = (selected) => choiceColumnModels(
      catalog,
      [context.address],
      () => [
        {
          kind: "collection",
          name: "children",
          resolver: { relation: "children", type: "catalog" },
          selected: selected === "children",
        },
        { kind: "collection", name: "contexts", selected: selected === "contexts" },
        { name: "unsupported", selected: selected === "unsupported" },
      ],
    );

    expect(modelsFor("children").map(({ mode }) => mode)).toEqual(["children"]);
    expect(modelsFor("contexts").map(({ mode }) => mode)).toEqual(["contexts"]);
    expect(modelsFor("unsupported")).toEqual([]);
  });

  test("restores vertical offsets only for columns representing the same parent", () => {
    let rendered = [
      { dataset: { scrollKey: "root" }, scrollTop: 17 },
      { dataset: { scrollKey: "children:.dev/rust" }, scrollTop: 559 },
    ];
    const columns = {
      querySelectorAll() {
        return rendered;
      },
    };
    const offsets = captureColumnScrollOffsets(columns);

    rendered = [
      { dataset: { scrollKey: "root" }, scrollTop: 0 },
      { dataset: { scrollKey: "children:.dev/rust" }, scrollTop: 0 },
      { dataset: { scrollKey: "children:proj" }, scrollTop: 0 },
    ];
    restoreColumnScrollOffsets(columns, offsets);

    expect(rendered.map((column) => column.scrollTop)).toEqual([17, 559, 0]);
  });
});
