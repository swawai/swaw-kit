import { describe, expect, test } from "bun:test";

import {
  commandAtPath,
  commandPath,
  parseCommandPath,
  parseCommandSelection,
  parseCommandFacet,
  restoreCommandSelection,
  updateCommandPath,
} from "./navigation.js";
import { createSubjectFacetView } from "./subject-facet.js";

describe("command URL contract", () => {
  test("maps System and Module identities to explicit paths", () => {
    expect(commandPath({
      space: "module",
      namespace: "project",
      path: ["build", "launcher"],
      address: "project/build/launcher",
    })).toBe("/commands/module/project/build/launcher");
    expect(commandPath({ space: "system", address: ".dev/setup" }))
      .toBe("/commands/system/dev/setup");
    expect(commandPath({ space: "system", address: "" }))
      .toBe("/commands/system");
    expect(commandPath({ space: "system", address: ".dev/rust" }))
      .toBe("/commands/system/dev/rust");
    expect(commandPath({
      space: "system",
      address: ".dev/rust/mode",
    })).toBe(
      "/commands/system/dev/rust/mode",
    );
  });

  test("parses canonical paths without relying on dot segments", () => {
    expect(parseCommandPath("/commands/module/project/build/app"))
      .toEqual({ space: "module", namespace: "project", address: "project/build/app" });
    expect(parseCommandPath("/commands/system/dev/setup"))
      .toEqual({ space: "system", namespace: null, address: ".dev/setup" });
    expect(parseCommandPath("/commands/system/entry"))
      .toEqual({ space: "system", namespace: null, address: ".entry" });
    expect(parseCommandPath(
      "/commands/system/dev/rust/mode",
    )).toEqual({
      space: "system",
      namespace: null,
      address: ".dev/rust/mode",
    });
    expect(parseCommandPath("/commands/system"))
      .toEqual({ space: "system", namespace: null, address: "" });
    expect(parseCommandPath("/")).toBeNull();
  });

  test("rejects invalid or missing commands", () => {
    expect(() => parseCommandPath("/other/module/demo")).toThrow("不是有效");
    expect(() => parseCommandPath("/commands/module")).toThrow("缺少");
    expect(() => parseCommandPath("/commands/module/Bad")).toThrow("无效");
    expect(() => parseCommandPath(
      "/commands/system/entry/env/SWAWKIT_PROJ_BUN_MODE",
    )).toThrow("无效");
    const catalog = {
      commandByAddress: new Map([
        ["demo", { space: "module", namespace: "demo", address: "demo" }],
      ]),
    };
    expect(() => commandAtPath(catalog, "/commands/module/missing"))
      .toThrow("不存在");
    expect(commandAtPath(
      catalog,
      "/commands/module/missing",
      { allowMissing: true },
    )).toBeNull();
  });

  test("pushes user navigation and replaces initialization", () => {
    const calls = [];
    const history = {
      pushState(_state, _title, path) { calls.push(["push", path]); },
      replaceState(_state, _title, path) { calls.push(["replace", path]); },
    };
    const location = { pathname: "/", search: "" };
    const command = { space: "module", namespace: "demo", path: [], address: "demo" };

    updateCommandPath(history, location, command, { mode: "replace" });
    updateCommandPath(history, location, command, { mode: "push" });
    location.pathname = "/commands/module/demo";
    updateCommandPath(history, location, command, { mode: "push" });

    expect(calls).toEqual([
      ["replace", "/commands/module/demo"],
      ["push", "/commands/module/demo"],
    ]);
  });

  test("round-trips non-default Facets without encoding default UI state", () => {
    expect(parseCommandFacet("")).toBeNull();
    expect(parseCommandFacet("?facet=help")).toBe("help");
    expect(parseCommandFacet("?facet=edit")).toBe("edit");
    expect(parseCommandFacet("?facet=runs")).toBe("runs");
    expect(parseCommandFacet("?facet=runs")).toBe("runs");
    expect(parseCommandFacet("?facet=validate")).toBe("validate");
    expect(() => parseCommandFacet("?facet=Invalid")).toThrow("无效");
    expect(() => parseCommandFacet("?facet=help&facet=run")).toThrow("只能");
    expect(() => parseCommandFacet("?facet=help&draft=1")).toThrow("参数");

    const calls = [];
    const history = {
      pushState(_state, _title, path) { calls.push(path); },
      replaceState() {},
    };
    const location = {
      pathname: "/commands/module/project/build",
      search: "",
    };
    const command = {
      space: "module",
      namespace: "project",
      path: ["build"],
      address: "project/build",
    };

    updateCommandPath(history, location, command, {
      defaultFacet: "children",
      facet: "help",
    });
    updateCommandPath(history, location, command, {
      defaultFacet: "children",
      facet: "children",
    });
    updateCommandPath(history, location, command, {
      defaultFacet: "children",
      facet: "runs",
    });

    expect(calls).toEqual([
      "/commands/module/project/build?facet=help",
      "/commands/module/project/build?facet=runs",
    ]);
  });

  test("keeps typed Subject identity and both Facets in query state", () => {
    expect(parseCommandSelection("?facet=runs&subject=%3A%3Arun%2F20260816-001&subject-facet=cancel"))
      .toEqual({
        facet: "runs",
        subject: "::run/20260816-001",
        subjectFacet: "cancel",
      });
    expect(() => parseCommandSelection("?subject=%3A%3Arun%2Frun-01"))
      .toThrow("Facet");
    expect(() => parseCommandSelection("?facet=runs&subject=run-01"))
      .toThrow("无效");
    for (const invalid of ["::run/Bad", "::run/has/slash", "::run/has space"]) {
      expect(() => parseCommandSelection(`?facet=runs&subject=${encodeURIComponent(invalid)}`))
        .toThrow("无效");
    }
    expect(() => parseCommandSelection("?facet=runs&subject=%3A%3Arun%2Fone&subject=%3A%3Arun%2Ftwo"))
      .toThrow("只能");

    expect(parseCommandSelection("?facet=runs")).toEqual({
      facet: "runs",
      subject: null,
      subjectFacet: null,
    });

    const calls = [];
    const history = {
      pushState(_state, _title, path) { calls.push(path); },
      replaceState() {},
    };
    updateCommandPath(
      history,
      { pathname: "/commands/module/swaw/context", search: "" },
      {
        space: "module",
        namespace: "swaw",
        path: ["context"],
        address: "swaw/context",
      },
      {
        defaultSubjectFacet: "overview",
        facet: "runs",
        subject: "::run/run-01",
        subjectFacet: "cancel",
      },
    );
    expect(calls).toEqual([
      "/commands/module/swaw/context?facet=runs&subject=%3A%3Arun%2Frun-01&subject-facet=cancel",
    ]);
  });

  test("restores the owner before an asynchronous collection and its Subject", async () => {
    const events = [];
    const facetView = createSubjectFacetView();
    let finishCollection;
    let loadedCollection = null;
    const restored = restoreCommandSelection({
      collectionFacet: "contexts",
      loadCollection(owner, facet) {
        events.push(["load", owner, facet]);
        return new Promise((resolve) => {
          finishCollection = (collection) => {
            loadedCollection = collection;
            resolve(collection);
          };
        });
      },
      ownerAddress: "swaw/context",
      selectOwner() {
        events.push(["owner", "swaw/context", "contexts"]);
        return true;
      },
      selectSubject(owner, facet, subject, options) {
        const selected = loadedCollection.subjects.find(
          (candidate) => candidate.canonicalRef === subject,
        );
        const selectedFacet = facetView.select(selected, options).selectedFacet;
        events.push(["subject", owner, facet, subject, selectedFacet]);
        return Boolean(selected);
      },
      subjectFacet: null,
      subjectRef: "::context/test",
    });

    expect(events).toEqual([
      ["owner", "swaw/context", "contexts"],
      ["load", "swaw/context", "contexts"],
    ]);
    finishCollection({
      subjects: [{
        canonicalRef: "::context/test",
        facets: [{
          icon: "i",
          id: "overview",
          kind: "projection",
          label: "Overview",
          renderer: "overview",
          resolver: {
            acceptsTail: false,
            address: "swaw/context/show",
            arguments: ["test"],
            confirmation: null,
            returns: "swawkit.context/v2",
            type: "command",
          },
          summary: "Inspect Context",
        }],
      }],
    });
    expect(await restored).toBeTrue();
    expect(events[2]).toEqual([
      "subject",
      "swaw/context",
      "contexts",
      "::context/test",
      "overview",
    ]);
  });
});
