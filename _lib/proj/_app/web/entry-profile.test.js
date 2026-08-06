import assert from "node:assert/strict";
import test from "node:test";

import {
  EntryProfileConflictError,
  putEntryProfileVariable,
} from "./entry-profile.js";

test("variable updates use the command's environment name and loaded revision", async () => {
  let request;
  const document = {
    protocol: "swawkit.entry-profile-state/v3",
    revision: "sha256-next",
    variables: { SWAWKIT_PROJ_DEFAULT_SHELL: "pwsh" },
  };
  const result = await putEntryProfileVariable(
    "SWAWKIT_PROJ_DEFAULT_SHELL",
    "pwsh",
    "sha256-loaded",
    async (url, options) => {
      request = { url, options };
      return {
        ok: true,
        status: 200,
        async json() {
          return document;
        },
      };
    },
  );

  assert.equal(
    request.url,
    "/api/v2/profile/variables/SWAWKIT_PROJ_DEFAULT_SHELL",
  );
  assert.equal(request.options.headers["If-Match"], '"sha256-loaded"');
  assert.deepEqual(JSON.parse(request.options.body), { value: "pwsh" });
  assert.deepEqual(result, document);
});

test("profile conflicts are distinguishable from validation failures", async () => {
  await assert.rejects(
    putEntryProfileVariable("SWAWKIT_PROJ_DEFAULT_SHELL", "pwsh", "stale", async () => ({
      ok: false,
      status: 409,
      async json() {
        return { error: "changed" };
      },
    })),
    EntryProfileConflictError,
  );
});
