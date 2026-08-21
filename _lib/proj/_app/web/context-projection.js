import { createContextProjection } from "./context-projection-model.js";

export const CONTEXT_PROTOCOL = "swawkit.context/v2";

function renderList(list, empty, values, renderValue) {
  list.replaceChildren(...values.map((value) => {
    const item = document.createElement("li");
    renderValue(item, value);
    return item;
  }));
  empty.hidden = values.length !== 0;
}

export function renderContextFields(elements, document_) {
  renderList(
    elements.commands,
    elements.commandEmpty,
    document_.commands,
    (item, command) => {
      const address = document.createElement("code");
      address.textContent = command.address;
      const identity = document.createElement("span");
      identity.textContent = command.namespace
        ? `${command.space}:${command.namespace}`
        : command.space;
      item.append(address, identity);
    },
  );
  renderList(
    elements.notes,
    elements.notesEmpty,
    document_.notes,
    (item, note) => { item.textContent = note; },
  );
  elements.prompt.textContent = document_.prompt;
  elements.prompt.hidden = document_.prompt.length === 0;
  elements.promptEmpty.hidden = document_.prompt.length !== 0;
}

export function createContextProjectionRenderer(elements, options = {}) {
  const onPin = options.onPin ?? (() => {});
  let pinnedRef = null;
  let selectedDocument = null;
  let selectedResource = null;

  function updatePin() {
    const pinned = selectedResource?.route === pinnedRef;
    elements.contextProjectionPin.disabled = pinned || !selectedResource;
    elements.contextProjectionPinLabel.hidden = pinned;
    elements.contextProjectionPinnedLabel.hidden = !pinned;
  }

  function clear() {
    elements.contextProjectionCommands.replaceChildren();
    elements.contextProjectionNotes.replaceChildren();
    elements.contextProjectionPrompt.textContent = "";
    elements.contextProjectionCommandEmpty.hidden = false;
    elements.contextProjectionNotesEmpty.hidden = false;
    elements.contextProjectionPrompt.hidden = true;
    elements.contextProjectionPromptEmpty.hidden = false;
    selectedDocument = null;
    selectedResource = null;
    updatePin();
  }

  function hide() {
    elements.contextProjectionPane.hidden = true;
    clear();
  }

  function render(resource, payload) {
    const document_ = createContextProjection(payload, resource.identity.id);
    selectedDocument = document_;
    selectedResource = resource;
    elements.contextProjectionTitle.textContent = resource.label;
    elements.contextProjectionRef.textContent = resource.route;
    elements.contextProjectionSummary.textContent = resource.summary;
    renderContextFields({
      commandEmpty: elements.contextProjectionCommandEmpty,
      commands: elements.contextProjectionCommands,
      notes: elements.contextProjectionNotes,
      notesEmpty: elements.contextProjectionNotesEmpty,
      prompt: elements.contextProjectionPrompt,
      promptEmpty: elements.contextProjectionPromptEmpty,
    }, document_);
    updatePin();
    elements.contextProjectionPane.hidden = false;
  }

  function setPinnedRef(reference) {
    pinnedRef = reference;
    updatePin();
  }

  elements.contextProjectionPin.addEventListener("click", () => {
    if (selectedResource && selectedDocument) {
      onPin(selectedResource, selectedDocument);
    }
  });

  updatePin();
  return { hide, protocol: CONTEXT_PROTOCOL, render, setPinnedRef };
}
