import { defaultEntryPage, entryPage, isEntryPage } from "./entry-navigation.js";

export class EntryProfileConflictError extends Error {}

export async function putEntryProfile(profile, revision, fetchProfile = fetch) {
  const response = await fetchProfile("/api/v2/profile", {
    method: "PUT",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
      "If-Match": `"${revision}"`,
    },
    body: JSON.stringify(profile),
  });
  const document = await response.json();
  if (response.status === 409) {
    throw new EntryProfileConflictError(document.error);
  }
  if (!response.ok) {
    throw new Error(document.error || `Host 返回 HTTP ${response.status}`);
  }
  return document;
}

export function createEntryProfileView(elements, { onProfileChanged }) {
  let currentProfile = null;
  let currentRevision = "missing";
  let currentPage = defaultEntryPage();

  function field(name) {
    return elements.profileForm.elements.namedItem(name);
  }

  function setField(name, value) {
    const control = field(name);
    if (control) {
      control.value = value ?? "";
    }
  }

  function render(page = defaultEntryPage()) {
    const selectedPage = isEntryPage(page) ? page : defaultEntryPage();
    currentPage = selectedPage;
    const descriptor = entryPage(selectedPage);
    elements.entryProfileTitle.textContent = descriptor.title;
    elements.entryProfileSummary.textContent = descriptor.summary;
    elements.profileForm.hidden = false;
    for (const section of elements.profileForm.querySelectorAll("[data-profile-section]")) {
      section.hidden = section.dataset.profileSection !== selectedPage;
    }
    elements.entryProfileDetail.hidden = false;
    elements.commandDetail.hidden = true;
    elements.selectionStatus.textContent = `已选择${descriptor.title}`;
  }

  function updateConditionalRequirements() {
    for (const [modeName, valueName, enabledMode] of [
      ["development.bun.mode", "development.bun.version", "managed"],
      ["development.pwsh.mode", "development.pwsh.version", "managed"],
      ["development.msvc.mode", "development.msvc.channel", "managed"],
      ["development.rust.mode", "development.rust.toolchain", "rustup"],
    ]) {
      field(valueName).required = field(modeName).value === enabledMode;
    }
  }

  function populate(profile) {
    currentProfile = profile;
    setField("targetProjectRoot", profile.targetProjectRoot);
    setField("preferences.defaultShell", profile.preferences.defaultShell);
    setField("preferences.defaultIde", profile.preferences.defaultIde);
    setField("preferences.helpLanguage", profile.preferences.helpLanguage);

    for (const name of ["bun", "pwsh", "uv", "python", "go"]) {
      setField(`development.${name}.mode`, profile.development[name].mode);
      setField(`development.${name}.version`, profile.development[name].version);
      setField(`development.${name}.sha256`, profile.development[name].sha256);
    }
    setField("development.msvc.mode", profile.development.msvc.mode);
    setField("development.msvc.channel", profile.development.msvc.channel);
    for (const name of ["mode", "toolchain", "profile", "host"]) {
      setField(`development.rust.${name}`, profile.development.rust[name]);
    }
    for (const name of ["gh", "vscode", "cursor"]) {
      setField(`development.${name}.mode`, profile.development[name].mode);
    }

    setField("git.name", profile.git.name);
    setField("git.email", profile.git.email);
    setField("git.access", profile.git.access);
    setField("repository.remote", profile.repository.remote);
    updateConditionalRequirements();
  }

  function readVersionedTool(name) {
    return {
      mode: field(`development.${name}.mode`).value,
      version: field(`development.${name}.version`).value,
      sha256: field(`development.${name}.sha256`).value,
    };
  }

  function readProfile() {
    return {
      schema: currentProfile.schema,
      targetProjectRoot: field("targetProjectRoot").value,
      preferences: {
        defaultShell: field("preferences.defaultShell").value,
        defaultIde: field("preferences.defaultIde").value,
        helpLanguage: field("preferences.helpLanguage").value,
      },
      development: {
        bun: readVersionedTool("bun"),
        pwsh: readVersionedTool("pwsh"),
        msvc: {
          mode: field("development.msvc.mode").value,
          channel: field("development.msvc.channel").value,
        },
        rust: {
          mode: field("development.rust.mode").value,
          toolchain: field("development.rust.toolchain").value,
          profile: field("development.rust.profile").value,
          host: field("development.rust.host").value,
        },
        uv: readVersionedTool("uv"),
        python: readVersionedTool("python"),
        go: readVersionedTool("go"),
        gh: { mode: field("development.gh.mode").value },
        vscode: { mode: field("development.vscode.mode").value },
        cursor: { mode: field("development.cursor.mode").value },
      },
      git: {
        name: field("git.name").value,
        email: field("git.email").value,
        access: field("git.access").value,
      },
      repository: { remote: field("repository.remote").value },
    };
  }

  function renderProfile(document) {
    currentRevision = document.revision;
    populate(document.profile);
    elements.profileResolvedRoot.textContent = document.resolvedTargetProjectRoot || "—";
    elements.profileState.dataset.state = document.status;
    if (document.status === "ready") {
      elements.profileState.textContent = "Entry 配置已生效";
    } else if (document.status === "invalid") {
      elements.profileState.textContent = document.error || "Entry 配置无效";
    } else {
      elements.profileState.textContent = "请保存首次设置以解锁命令目录";
    }
    return document;
  }

  async function loadProfile() {
    elements.profileState.dataset.state = "loading";
    elements.profileState.textContent = "正在读取 Entry 配置…";
    const response = await fetch("/api/v2/profile", {
      cache: "no-store",
      headers: { Accept: "application/json" },
    });
    if (!response.ok) {
      throw new Error(`Host 返回 HTTP ${response.status}`);
    }
    return renderProfile(await response.json());
  }

  async function saveProfile() {
    updateConditionalRequirements();
    if (!elements.profileForm.reportValidity()) {
      return;
    }
    elements.profileSaveButton.disabled = true;
    elements.profileFeedback.dataset.state = "";
    elements.profileFeedback.textContent = "正在保存…";
    try {
      const document = await putEntryProfile(readProfile(), currentRevision);
      renderProfile(document);
      elements.profileFeedback.textContent = "配置已保存";
      await onProfileChanged(document, currentPage);
    } catch (error) {
      elements.profileFeedback.dataset.state = "error";
      if (error instanceof EntryProfileConflictError) {
        try {
          const latest = await loadProfile();
          await onProfileChanged(latest, currentPage);
          elements.profileFeedback.textContent = "配置已被其他进程修改，已重新载入最新版本；请确认后再次保存。";
        } catch {
          elements.profileFeedback.textContent = "配置已被其他进程修改，请重新加载页面后再保存。";
        }
      } else {
        elements.profileFeedback.textContent = error instanceof Error
          ? error.message
          : "保存配置时发生未知错误";
      }
    } finally {
      elements.profileSaveButton.disabled = false;
    }
  }

  for (const mode of elements.profileForm.querySelectorAll("select[name$='.mode']")) {
    mode.addEventListener("change", updateConditionalRequirements);
  }

  return {
    loadProfile,
    render,
    saveProfile,
  };
}
