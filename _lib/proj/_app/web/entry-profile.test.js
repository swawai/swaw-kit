import assert from "node:assert/strict";
import test from "node:test";

import {
  EntryProfileConflictError,
  putEntryProfile,
} from "./entry-profile.js";

test("profile updates send the loaded revision as a strong If-Match tag", async () => {
  let request;
  const document = { revision: "sha256-next", profile: {} };
  const result = await putEntryProfile(
    { schema: "swawkit.entry-profile/v1" },
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

  assert.equal(request.url, "/api/v2/profile");
  assert.equal(request.options.headers["If-Match"], '"sha256-loaded"');
  assert.deepEqual(result, document);
});

test("profile conflicts are distinguishable from validation failures", async () => {
  await assert.rejects(
    putEntryProfile({}, "stale", async () => ({
      ok: false,
      status: 409,
      async json() {
        return { error: "changed" };
      },
    })),
    EntryProfileConflictError,
  );
});
