import { commandRef } from "./command-identity.js";
import { createResourceList } from "./resource-list-model.js";
import {
  canonicalFacetRoute,
  commandFacetRoute,
  normalizeFacetRoute,
} from "./resource-route.js";

const VIEW_BUNDLE_PROTOCOL = "swawkit.view-bundle/web/v1";
const FACET_RESULT = "facet-result";

function invalid(message) {
  return new Error(`Invalid Web View Bundle protocol: ${message}`);
}

function object(value, field) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw invalid(`${field} must be an object.`);
  }
  return value;
}

function exactKeys(value, expected, field) {
  const actual = Object.keys(value).sort();
  const keys = [...expected].sort();
  if (actual.length !== keys.length || actual.some((key, index) => key !== keys[index])) {
    throw invalid(`${field} has an invalid shape.`);
  }
}

export function createViewBundle(document, catalog, owner, collectionFacet) {
  const payload = object(document, "View Bundle");
  exactKeys(payload, ["protocol", "resources", "target", "view"], "View Bundle");
  if (payload.protocol !== VIEW_BUNDLE_PROTOCOL) {
    throw invalid(`protocol must be ${VIEW_BUNDLE_PROTOCOL}.`);
  }
  if (!owner || collectionFacet?.kind !== "collection") {
    throw invalid("the selected Facet is not a Collection.");
  }

  const target = normalizeFacetRoute(payload.target, "target", invalid);
  const targetRoute = canonicalFacetRoute(target);
  if (targetRoute !== commandFacetRoute(commandRef(owner), collectionFacet.id)) {
    throw invalid("target does not match the requested Collection Facet.");
  }

  const view = object(payload.view, "view");
  exactKeys(view, ["body", "width"], "view");
  if (view.width !== "normal" && view.width !== "wide") {
    throw invalid("view.width is not supported.");
  }
  const body = object(view.body, "view.body");
  exactKeys(body, ["component", "source"], "view.body");
  if (body.component !== "resource-list" || body.source !== FACET_RESULT) {
    throw invalid("view.body must render the resolved Facet Resource List.");
  }

  const resources = object(payload.resources, "resources");
  exactKeys(resources, [FACET_RESULT], "resources");
  const resourceList = createResourceList(
    resources[FACET_RESULT],
    catalog,
    owner,
    collectionFacet,
  );
  if (resourceList.source !== targetRoute) {
    throw invalid("the Resource List does not belong to the View target.");
  }
  return {
    protocol: VIEW_BUNDLE_PROTOCOL,
    resourceList,
    target: targetRoute,
    view: {
      body: { component: "resource-list", source: FACET_RESULT },
      width: view.width,
    },
  };
}
