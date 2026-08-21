export function availableCommand(catalog, address) {
  return catalog.commandByAddress.get(address) ?? null;
}

export function commandHasChoices(_catalog, _command, facets) {
  return facets.length > 0;
}

export function commandMenuExpanded(expandedAddress, address) {
  return expandedAddress === address;
}

export function selectedCommandFacet(facets) {
  return facets.find((facet) => facet.selected)?.name ?? null;
}

export function viewColumnWidth(collectionView) {
  return collectionView?.view?.width === "wide" ? "wide" : "normal";
}

export function choiceColumnModels(
  catalog,
  selectedPath,
  getViews,
  selectedResourceList = null,
) {
  return selectedPath.flatMap((address, index) => {
    const command = catalog.commandByAddress.get(address);
    if (!command) {
      return [];
    }
    const facets = getViews(command);
    const terminal = index === selectedPath.length - 1;
    if (!terminal) {
      const subcommands = facets.find((facet) => (
        facet.kind === "collection"
        && facet.resolver?.type === "catalog"
        && facet.resolver.relation === "subcommands"
      ));
      return subcommands
        ? [{ command, depth: index + 1, mode: subcommands.name }]
        : [];
    }
    if (selectedResourceList?.owner === address) {
      return [{
        command,
        depth: index + 1,
        mode: selectedResourceList.facet,
      }];
    }
    const facet = facets.find(({ selected }) => selected);
    return facet?.kind === "collection"
      ? [{ command, depth: index + 1, mode: facet.name }]
      : [];
  });
}
