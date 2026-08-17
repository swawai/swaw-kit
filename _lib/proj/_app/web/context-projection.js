import { createContextProjection } from "./context-projection-model.js";

export const CONTEXT_PROTOCOL = "swawkit.context/v1";

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
      const source = document.createElement("span");
      source.textContent = command.source;
      item.append(address, source);
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
  let selectedSubject = null;

  function updatePin() {
    const pinned = selectedSubject?.canonicalRef === pinnedRef;
    elements.contextProjectionPin.disabled = pinned || !selectedSubject;
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
    selectedSubject = null;
    updatePin();
  }

  function hide() {
    elements.contextProjectionPane.hidden = true;
    clear();
  }

  function render(subject, payload) {
    const document_ = createContextProjection(payload, subject.ref.id);
    selectedDocument = document_;
    selectedSubject = subject;
    elements.contextProjectionTitle.textContent = subject.label;
    elements.contextProjectionRef.textContent = subject.canonicalRef;
    elements.contextProjectionSummary.textContent = subject.summary;
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
    if (selectedSubject && selectedDocument) {
      onPin(selectedSubject, selectedDocument);
    }
  });

  updatePin();
  return { hide, protocol: CONTEXT_PROTOCOL, render, setPinnedRef };
}
