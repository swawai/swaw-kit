const RUNTIME_STATUS_HANDLER = "runtime.status";

export function resourceFacets(resource) {
  return resource?.facets ?? [];
}

export function resourceFacetItems(resource) {
  return resourceFacets(resource).map((facet) => ({
    ...facet,
    name: facet.id,
  }));
}

export function defaultResourceFacet(resource) {
  const facets = resourceFacetItems(resource);
  if (resource?.handler === RUNTIME_STATUS_HANDLER) {
    return facets.find((facet) => facet.renderer === "overview")?.name ?? null;
  }
  return facets[0]?.name ?? null;
}

export function defaultCommandFacet(command) {
  const facets = resourceFacetItems(command);
  if (command?.handler === RUNTIME_STATUS_HANDLER) {
    return null;
  }
  return facets.find((facet) => facet.renderer === "edit")?.name
    ?? facets.find((facet) => facet.kind === "collection" && facet.name !== "runs")?.name
    ?? null;
}

export function createResourceFacetView(elements = null, options = {}) {
  const panes = elements
    ? new Map([
      ["edit", elements.entryConfigDetail],
      ["overview", elements.commandDetail],
      ["help", elements.commandHelpPane],
      ["run", elements.commandRunPane],
    ])
    : new Map();
  const workspaceRenderers = new Set(["overview", "help", "run"]);
  let available = [];
  let selected = null;
  let selectedRef = null;
  let hasResource = false;
  const chooseDefault = options.defaultFacet ?? defaultResourceFacet;
  const fallbackRenderer = options.fallbackRenderer ?? null;

  function selectedFacet() {
    return available.find((facet) => facet.name === selected) ?? null;
  }

  function render() {
    if (!elements) {
      return;
    }
    const renderer = selectedFacet()?.renderer ?? (hasResource ? fallbackRenderer : null);
    elements.commandWorkspace.hidden = !workspaceRenderers.has(renderer);
    for (const [candidate, pane] of panes) {
      pane.hidden = candidate !== renderer;
    }
  }

  function select(resource, { facet = null } = {}) {
    available = resourceFacetItems(resource);
    const defaultFacet = chooseDefault(resource);
    const selectable = new Set(available.map((candidate) => candidate.name));
    selected = selectable.has(facet) ? facet : defaultFacet;
    selectedRef = resource?.route ?? resource?.address ?? null;
    hasResource = resource !== null && resource !== undefined;
    render();
    return {
      defaultFacet,
      facet: selectedFacet(),
      selectedFacet: selected,
    };
  }

  function items(resource) {
    const reference = resource?.route ?? resource?.address ?? null;
    return resourceFacetItems(resource).map((facet) => ({
      ...facet,
      selected: reference === selectedRef && facet.name === selected,
    }));
  }

  render();
  return { items, select };
}
