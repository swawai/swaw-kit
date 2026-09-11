import { t } from "./i18n.js";
import { commandIdentityKey } from "./command-identity.js";

export function createDocumentProjectionView(elements, options = {}) {
  const renderers = new Map((options.renderers ?? []).map((renderer) => [
    renderer.protocol,
    renderer,
  ]));
  const resolveDocument = options.resolveDocument ?? (() => {
    throw new Error("No document projection resolver is configured.");
  });
  let requestVersion = 0;
  let selectedKey = null;

  function resourceKey(resource) {
    return resource?.route ?? commandIdentityKey(resource);
  }

  function hideRenderers() {
    for (const renderer of renderers.values()) {
      renderer.hide();
    }
  }

  function showGeneric(resource, facet, state, message = "") {
    elements.documentProjectionTitle.textContent = facet?.label ?? "";
    elements.documentProjectionRef.textContent = resourceKey(resource);
    elements.documentProjectionProtocol.textContent = facet?.resolver?.returns ?? "";
    elements.documentProjectionFeedback.dataset.state = state;
    elements.documentProjectionFeedback.textContent = message;
    elements.documentProjectionJson.hidden = true;
    elements.documentProjectionPane.hidden = false;
  }

  function clear() {
    requestVersion += 1;
    selectedKey = null;
    hideRenderers();
    elements.documentProjectionPane.hidden = true;
    elements.documentProjectionFeedback.textContent = "";
    elements.documentProjectionJson.textContent = "";
    elements.documentProjectionJson.hidden = true;
  }

  async function load(resource, facet, version, key) {
    try {
      const document_ = await resolveDocument(resource, facet);
      if (version !== requestVersion || selectedKey !== key) {
        return;
      }
      const renderer = renderers.get(facet.resolver.returns);
      if (renderer) {
        renderer.render(resource, document_);
        elements.documentProjectionPane.hidden = true;
        return;
      }
      elements.documentProjectionFeedback.textContent = "";
      elements.documentProjectionJson.textContent = JSON.stringify(document_, null, 2);
      elements.documentProjectionJson.hidden = false;
    } catch (error) {
      if (version !== requestVersion || selectedKey !== key) {
        return;
      }
      hideRenderers();
      elements.documentProjectionPane.hidden = false;
      elements.documentProjectionFeedback.dataset.state = "error";
      elements.documentProjectionFeedback.textContent = error instanceof Error
        ? error.message
        : t("解析文档 Facet 时发生未知错误。", "An unknown error occurred while resolving the document Facet.");
    }
  }

  function select(resource, facet) {
    clear();
    if (facet?.kind !== "projection" || facet.resolver?.type !== "command") {
      return false;
    }
    const key = `${resourceKey(resource)}#${facet.id}`;
    selectedKey = key;
    showGeneric(resource, facet, "", t("正在解析文档…", "Resolving document…"));
    void load(resource, facet, requestVersion, key);
    return true;
  }

  return { clear, select };
}
