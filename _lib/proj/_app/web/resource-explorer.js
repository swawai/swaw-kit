import { t } from "./i18n.js";

function facetMenuId(resource) {
  return `resource-facet-menu-${resource.selector}`;
}

function createFacetRow(documentObject, resource, facet, onSelect) {
  const item = documentObject.createElement("li");
  const button = documentObject.createElement("button");
  const icon = documentObject.createElement("span");
  const name = documentObject.createElement("span");

  button.type = "button";
  button.className = "finder-choice command-facet-row resource-facet-row";
  button.dataset.facet = facet.name;
  button.dataset.parentAddress = resource.owner;
  button.dataset.resourceRoute = resource.route;
  button.dataset.navigationKey = `${resource.route}/${facet.name}`;
  button.setAttribute("aria-pressed", String(facet.selected));
  button.title = facet.summary;

  icon.className = "row-icon facet-icon";
  icon.textContent = facet.icon;
  icon.setAttribute("aria-hidden", "true");
  name.className = "row-name";
  name.textContent = facet.label;
  button.append(icon, name);
  button.addEventListener("click", () => onSelect(resource, {
    focusDetail: true,
    history: "push",
    facet: facet.name,
  }));
  item.append(button);
  return item;
}

function createFacetMenu(documentObject, resource, facets, onSelect) {
  const group = documentObject.createElement("div");
  const list = documentObject.createElement("ul");
  group.className = "command-facet-group resource-facet-group";
  list.className = "command-facet-menu";
  list.id = facetMenuId(resource);
  list.setAttribute("aria-label", `${resource.route} facets`);
  for (const facet of facets) {
    list.append(createFacetRow(documentObject, resource, facet, onSelect));
  }
  group.append(list);
  return group;
}

function createResourceRow(
  documentObject,
  resource,
  selectedResourceRoute,
  getResourceFacets,
  onSelect,
) {
  const item = documentObject.createElement("li");
  const button = documentObject.createElement("button");
  const icon = documentObject.createElement("span");
  const copy = documentObject.createElement("span");
  const name = documentObject.createElement("span");
  const summary = documentObject.createElement("span");
  const selected = resource.route === selectedResourceRoute;
  const facets = getResourceFacets(resource);

  button.type = "button";
  button.className = "finder-choice resource-row";
  button.dataset.parentAddress = resource.owner;
  button.dataset.resourceRoute = resource.route;
  button.dataset.navigationKey = resource.route;
  button.dataset.selected = String(selected);
  button.setAttribute("aria-expanded", String(selected));
  if (selected) {
    button.setAttribute("aria-current", "page");
    button.setAttribute("aria-controls", facetMenuId(resource));
  }
  button.title = resource.route;

  icon.className = "row-icon resource-icon";
  icon.textContent = "◆";
  icon.setAttribute("aria-hidden", "true");
  copy.className = "row-copy";
  name.className = "row-name";
  name.textContent = resource.label;
  summary.className = "row-summary";
  summary.textContent = resource.summary;
  copy.append(name, summary);
  button.append(icon, copy);
  button.addEventListener("click", (event) => onSelect(resource, {
    focusDetail: event.detail === 0,
    history: "push",
  }));
  item.className = "resource-item";
  item.append(button);
  if (selected && facets.length > 0) {
    item.append(createFacetMenu(documentObject, resource, facets, onSelect));
  }
  return item;
}

export function appendResourceSection({
  collection,
  column,
  documentObject = document,
  error = null,
  getResourceFacets,
  label = null,
  onSelect,
  selectedResourceRoute,
}) {
  const section = documentObject.createElement("section");
  const heading = documentObject.createElement("h2");
  section.className = "column-section resource-section";
  heading.className = "column-label";
  heading.textContent = collection?.label ?? label ?? t("正在读取…", "Loading…");
  section.append(heading);
  if (error) {
    const feedback = documentObject.createElement("p");
    feedback.className = "empty-column";
    feedback.dataset.state = "error";
    feedback.textContent = error;
    section.append(feedback);
    column.append(section);
    return;
  }
  if (!collection) {
    const loading = documentObject.createElement("p");
    loading.className = "empty-column";
    loading.textContent = t("正在读取…", "Loading…");
    section.append(loading);
    column.append(section);
    return;
  }
  const list = documentObject.createElement("ul");
  list.className = "column-list";
  for (const resource of collection.resources) {
    list.append(createResourceRow(
      documentObject,
      resource,
      selectedResourceRoute,
      getResourceFacets,
      onSelect,
    ));
  }
  section.append(list);
  if (collection.resources.length === 0) {
    const empty = documentObject.createElement("p");
    empty.className = "empty-column";
    empty.textContent = t("此集合中尚无资源。", "This collection has no resources yet.");
    section.append(empty);
  }
  column.append(section);
}
