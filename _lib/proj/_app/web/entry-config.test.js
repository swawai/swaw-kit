import assert from "node:assert/strict";
import test from "node:test";

import {
  EntryConfigConflictError,
  createEntryConfigView,
  normalizeEntryConfigDocument,
  putEntryConfigSetting,
} from "./entry-config.js";
import { RuntimeGenerationError } from "./runtime-generation.js";

function configDocument(revision, {
  language = "zh-CN",
  projectRoot = null,
  status = "ready",
  error = null,
} = {}) {
  return {
    protocol: "swawkit.entry-config-state/v1",
    revision,
    status,
    path: "D:/data/proj.swawkit/_entry-config.json",
    config: {
      schema: "swawkit.entry-config/v1",
      language,
      projectRoot,
    },
    settings: {
      ".entry/language": language,
      ".entry/project/root": projectRoot,
    },
    resolvedProjectRoot: status === "ready" ? projectRoot : null,
    error,
  };
}

function configElements() {
  const text = () => ({ textContent: "" });
  return {
    configFeedback: { dataset: {}, textContent: "" },
    configSaveButton: { disabled: false },
    configState: { dataset: {}, textContent: "" },
    configValue: { disabled: false, value: "" },
    configSettingAddress: text(),
    entryConfigSummary: text(),
    entryConfigTitle: text(),
    selectionStatus: text(),
  };
}

test("setting updates use the typed address and loaded revision", async () => {
  let request;
  const document = configDocument("sha256-next", { projectRoot: null });
  const result = await putEntryConfigSetting(
    ".entry/project/root",
    null,
    "sha256-loaded",
    async (url, options) => {
      request = { url, options };
      return {
        ok: true,
        status: 200,
        async json() { return document; },
      };
    },
  );

  assert.equal(
    request.url,
    "/api/v2/entry-config/settings/.entry%2Fproject%2Froot",
  );
  assert.equal(request.options.headers["If-Match"], '"sha256-loaded"');
  assert.deepEqual(JSON.parse(request.options.body), { value: null });
  assert.deepEqual(result, document);
});

test("old Profile and extended Entry Config wire shapes fail closed", () => {
  const retired = configDocument("sha256-retired");
  retired.protocol = "swawkit.entry-profile-state/v7";
  assert.throws(() => normalizeEntryConfigDocument(retired));

  const extended = configDocument("sha256-extended");
  extended.config.development = {};
  assert.throws(() => normalizeEntryConfigDocument(extended));
});

test("binding-unavailable state preserves the valid config", () => {
  const document = configDocument("sha256-unavailable", {
    language: "en",
    projectRoot: "D:/missing",
    status: "bindingUnavailable",
    error: "project root is unavailable",
  });
  assert.equal(normalizeEntryConfigDocument(document).config.language, "en");
});

test("semantic-invalid storage is represented by a valid default config plus error", () => {
  const document = configDocument("sha256-invalid", {
    status: "invalid",
    error: "unsupported entry config schema",
  });
  const normalized = normalizeEntryConfigDocument(document);
  assert.equal(normalized.config.schema, "swawkit.entry-config/v1");
  assert.equal(normalized.status, "invalid");
});

test("config conflicts are distinguishable from validation failures", async () => {
  await assert.rejects(
    putEntryConfigSetting(".entry/language", "en", "stale", async () => ({
      ok: false,
      status: 409,
      async json() { return { error: "changed" }; },
    })),
    EntryConfigConflictError,
  );
});

test("Runtime update conflicts remain distinct from config revision conflicts", async () => {
  const error = await putEntryConfigSetting(
    ".entry/language",
    "en",
    "loaded",
    async () => ({
      ok: false,
      status: 409,
      async json() {
        return { code: "runtimeUpdateRequired", error: "server detail" };
      },
    }),
  ).catch((caught) => caught);

  assert(error instanceof RuntimeGenerationError);
  assert.equal(error.code, "runtimeUpdateRequired");
});

test("a completed save does not overwrite a newer config command selection", async () => {
  const firstAddress = ".entry/language";
  const secondAddress = ".entry/project/root";
  const initial = configDocument("sha256-loaded", {
    projectRoot: "D:/old-project",
  });
  const updated = configDocument("sha256-next", {
    language: "en",
    projectRoot: "D:/old-project",
  });
  let resolveUpdate;
  const changed = [];
  const elements = configElements();
  const view = createEntryConfigView(elements, {
    async fetchImpl(url) {
      if (url === "/api/v2/entry-config") {
        return { ok: true, async json() { return initial; } };
      }
      return new Promise((resolve) => {
        resolveUpdate = () => resolve({
          ok: true,
          status: 200,
          async json() { return updated; },
        });
      });
    },
    async onConfigChanged(...arguments_) {
      changed.push(arguments_);
    },
  });
  const command = (address) => ({
    address,
    handler: "entry.config.set",
    summary: address,
  });

  await view.loadConfig();
  view.render(command(firstAddress));
  elements.configValue.value = "en";
  const saving = view.saveConfig();
  view.render(command(secondAddress));
  assert.equal(elements.configSaveButton.disabled, true);
  resolveUpdate();
  await saving;

  assert.equal(elements.entryConfigTitle.textContent, "root");
  assert.equal(elements.configValue.value, "D:/old-project");
  assert.equal(elements.configSaveButton.disabled, false);
  assert.equal(elements.configFeedback.textContent, "");
  assert.deepEqual(changed, [[updated]]);
});

test("an empty project root is sent as null", async () => {
  const initial = configDocument("sha256-loaded", { projectRoot: "D:/project" });
  const cleared = configDocument("sha256-next", { projectRoot: null });
  const elements = configElements();
  let body;
  const view = createEntryConfigView(elements, {
    async fetchImpl(url, options) {
      if (url === "/api/v2/entry-config") {
        return { ok: true, async json() { return initial; } };
      }
      body = JSON.parse(options.body);
      return { ok: true, status: 200, async json() { return cleared; } };
    },
    async onConfigChanged() {},
  });
  await view.loadConfig();
  view.render({
    address: ".entry/project/root",
    handler: "entry.config.set",
    summary: "root",
  });
  elements.configValue.value = "";
  await view.saveConfig();
  assert.deepEqual(body, { value: null });
});
