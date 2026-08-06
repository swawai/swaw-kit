import assert from "node:assert/strict";
import { test } from "bun:test";

import {
  DataRootClaimConflictError,
  DataRootClaimError,
  claimDetailValues,
  confirmDataRootClaim,
  createDataRootClaimView,
  matchesClaimConfirmation,
  readDataRootClaim,
} from "./claim.js";

const claim = {
  kind: "current",
  entryName: "swawkit",
  entryFile: "D:\\swaw-kit\\swawkit.exe",
  volumeId: "volume-id",
  fileId: "file-id",
  dataRoot: "D:\\swaw-kit\\data\\proj.swawkit",
  sourceDataRoot: null,
  reason: "File ID does not match the identity record",
};

function headers(etag = '"sha256-claim"') {
  return { get: (name) => name.toLowerCase() === "etag" ? etag : null };
}

function pendingResponse(document = {
  protocol: "swawkit.data-root-claim/v1",
  status: "claimRequired",
  claim,
}) {
  return {
    ok: true,
    status: 200,
    headers: headers(),
    async json() {
      return document;
    },
  };
}

function claimElements() {
  const element = (value = "") => ({
    textContent: "",
    value,
    disabled: false,
    dataset: {},
    addEventListener() {},
    focus() {},
  });
  return {
    claimConfirmation: element(),
    claimConfirmationName: element(),
    claimDataRoot: element(),
    claimEntryFile: element(),
    claimEntryName: element(),
    claimFeedback: element(),
    claimFileId: element(),
    claimForm: element(),
    claimKind: element(),
    claimReason: element(),
    claimSourceDataRoot: element(),
    claimSubmit: element(),
    claimVolumeId: element(),
  };
}

test("a 204 claim probe means the DataRoot is ready", async () => {
  const result = await readDataRootClaim(async () => ({
    ok: true,
    status: 204,
  }));
  assert.deepEqual(result, { status: "ready", warnings: [] });
});

test("a ready claim probe preserves repair warnings", async () => {
  const result = await readDataRootClaim(async () => ({
    ok: true,
    status: 200,
    headers: headers(),
    async json() {
      return {
        protocol: "swawkit.data-root-claim/v1",
        status: "ready",
        warnings: ["republish the development environment"],
      };
    },
  }));
  assert.deepEqual(result, {
    protocol: "swawkit.data-root-claim/v1",
    status: "ready",
    warnings: ["republish the development environment"],
  });
});

test("a pending claim preserves the server revision and every displayed field", async () => {
  const pending = await readDataRootClaim(async () => pendingResponse());

  assert.equal(pending.revision, '"sha256-claim"');
  assert.equal(pending.status, "claimRequired");
  assert.deepEqual(claimDetailValues(pending.claim), {
    ...claim,
    sourceDataRoot: "—",
  });
});

test("confirmation is exact and does not trim or fold case", () => {
  assert.equal(matchesClaimConfirmation(claim, "swawkit"), true);
  assert.equal(matchesClaimConfirmation(claim, "Swawkit"), false);
  assert.equal(matchesClaimConfirmation(claim, "swawkit "), false);
});

test("claim confirmation sends only the typed name with the loaded revision", async () => {
  let request;
  const result = await confirmDataRootClaim(
    { claim, revision: '"sha256-claim"' },
    "swawkit",
    async (url, options) => {
      request = { url, options };
      return {
        ok: true,
        status: 200,
        async json() {
          return {
            protocol: "swawkit.data-root-claim/v1",
            status: "claimed",
            warnings: ["recovered stale metadata"],
          };
        },
      };
    },
  );

  assert.equal(request.url, "/api/v2/data-root/claim");
  assert.equal(request.options.headers["If-Match"], '"sha256-claim"');
  assert.deepEqual(JSON.parse(request.options.body), { confirmation: "swawkit" });
  assert.deepEqual(result.warnings, ["recovered stale metadata"]);
});

test("claim documents require the exact v1 protocol", async () => {
  await assert.rejects(
    readDataRootClaim(async () => pendingResponse({
      protocol: "swawkit.data-root-claim/v2",
      status: "claimRequired",
      claim,
    })),
    DataRootClaimError,
  );

  await assert.rejects(
    confirmDataRootClaim(
      { claim, revision: '"sha256-claim"' },
      "swawkit",
      async () => ({
        ok: true,
        status: 200,
        async json() {
          return {
            protocol: "swawkit.data-root-claim/v2",
            status: "claimed",
            warnings: [],
          };
        },
      }),
    ),
    DataRootClaimError,
  );
});

test("a changed claim is distinguishable so the UI can refresh it", async () => {
  await assert.rejects(
    confirmDataRootClaim(
      { claim, revision: '"stale"' },
      "swawkit",
      async () => ({
        ok: false,
        status: 409,
        async json() {
          return { error: "claim changed" };
        },
      }),
    ),
    DataRootClaimConflictError,
  );
});

test("server validation errors preserve their message for inline feedback", async () => {
  await assert.rejects(
    confirmDataRootClaim(
      { claim, revision: '"sha256-claim"' },
      "swawkit",
      async () => ({
        ok: false,
        status: 422,
        async json() {
          return { error: "confirmation rejected" };
        },
      }),
    ),
    (error) => error instanceof DataRootClaimError
      && error.status === 422
      && error.message === "confirmation rejected",
  );
});

test("the view forwards claim warnings to the ready application", async () => {
  const elements = claimElements();
  const warnings = ["recovered stale metadata"];
  let request = 0;
  let readyWarnings;
  const view = createDataRootClaimView(elements, {
    onClaimRequired() {},
    async onReady(nextWarnings) {
      readyWarnings = nextWarnings;
    },
    async fetchClaim() {
      request += 1;
      if (request === 1) {
        return pendingResponse();
      }
      return {
        ok: true,
        status: 200,
        async json() {
          return {
            protocol: "swawkit.data-root-claim/v1",
            status: "claimed",
            warnings,
          };
        },
      };
    },
  });

  assert.equal(await view.ensureReady(), false);
  elements.claimConfirmation.value = "swawkit";
  await view.submit();
  assert.deepEqual(readyWarnings, warnings);
});

test("a failed conflict refresh remains an inline error", async () => {
  const elements = claimElements();
  let request = 0;
  const view = createDataRootClaimView(elements, {
    onClaimRequired() {},
    async onReady() {},
    async fetchClaim() {
      request += 1;
      if (request === 1) {
        return pendingResponse();
      }
      if (request === 2) {
        return {
          ok: false,
          status: 409,
          async json() {
            return { error: "claim changed" };
          },
        };
      }
      return {
        ok: false,
        status: 503,
        async json() {
          return { error: "refresh unavailable" };
        },
      };
    },
  });

  await view.ensureReady();
  elements.claimConfirmation.value = "swawkit";
  await view.submit();
  assert.equal(elements.claimFeedback.dataset.state, "error");
  assert.match(elements.claimFeedback.textContent, /refresh unavailable/);
});

test("a conflict refresh enters the application when another client completed the claim", async () => {
  const elements = claimElements();
  let request = 0;
  let readyWarnings;
  const view = createDataRootClaimView(elements, {
    onClaimRequired() {},
    async onReady(warnings) {
      readyWarnings = warnings;
    },
    async fetchClaim() {
      request += 1;
      if (request === 1) {
        return pendingResponse();
      }
      if (request === 2) {
        return {
          ok: false,
          status: 409,
          async json() {
            return { error: "claim changed" };
          },
        };
      }
      return { ok: true, status: 204 };
    },
  });

  await view.ensureReady();
  elements.claimConfirmation.value = "swawkit";
  await view.submit();

  assert.deepEqual(readyWarnings, []);
  assert.equal(request, 3);
});
