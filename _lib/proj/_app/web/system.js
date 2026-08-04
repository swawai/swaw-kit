const pageCopy = {
  overview: ["Swaw Kit", "Project Console"],
  project: ["项目绑定", "当前入口所控制的目标项目。"],
  preferences: ["交互偏好", "命令模块可共享的 Shell、IDE 与帮助语言声明。"],
  development: ["开发环境", "由项目管理或复用的开发工具声明。"],
  git: ["Git 与仓库", "按 Entry 隔离的可选身份、访问方式与远端信息。"],
  setup: ["首次设置", "完成必填信息后，命令目录才会解锁。"],
};

export function createSystemView(elements, { onProfileChanged }) {
  let currentProfile = null;
  let currentPage = "setup";
  let requiredComplete = false;

  function field(name) {
    return elements.profileForm.elements.namedItem(name);
  }

  function setField(name, value) {
    const control = field(name);
    if (control) {
      control.value = value ?? "";
    }
  }

  function setCatalog(catalog) {
    const kernelCount = catalog.commands
      .filter((command) => command.source === "kernel")
      .length;
    const actionCount = catalog.commands
      .filter((command) => command.source === "action")
      .length;

    elements.entryName.textContent = catalog.entryName;
    elements.protocolName.textContent = catalog.protocol;
    elements.catalogCount.textContent = String(catalog.commands.length);
    elements.kernelCount.textContent = String(kernelCount);
    elements.actionCount.textContent = String(actionCount);
    elements.hostAddress.textContent = window.location.origin;
  }

  function setStatus(status) {
    elements.connectionStatus.dataset.state = status;
    elements.connectionLabel.textContent = status === "loading"
      ? "正在读取命令目录…"
      : status === "error"
        ? "Host 不可用"
        : "Host 已连接";
  }

  function render(page = requiredComplete ? "overview" : "setup") {
    const selectedPage = requiredComplete ? page : "setup";
    currentPage = selectedPage;
    const [title, summary] = pageCopy[selectedPage] ?? pageCopy.overview;
    elements.systemTitle.textContent = title;
    elements.systemSummary.textContent = summary;
    elements.systemOverview.hidden = selectedPage !== "overview";
    elements.profileForm.hidden = selectedPage === "overview";
    elements.profileForm.dataset.page = selectedPage;
    for (const section of elements.profileForm.querySelectorAll("[data-profile-section]")) {
      section.hidden = selectedPage !== "setup"
        && section.dataset.profileSection !== selectedPage;
    }
    elements.systemDetail.hidden = false;
    elements.commandDetail.hidden = true;
    elements.selectionStatus.textContent = `已选择${title}`;
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
    requiredComplete = document.requiredComplete === true;
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
    const response = await fetch("/api/v1/profile", {
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
      const response = await fetch("/api/v1/profile", {
        method: "PUT",
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json",
        },
        body: JSON.stringify(readProfile()),
      });
      const document = await response.json();
      if (!response.ok) {
        throw new Error(document.error || `Host 返回 HTTP ${response.status}`);
      }
      renderProfile(document);
      elements.profileFeedback.textContent = "配置已保存";
      await onProfileChanged(document, currentPage);
    } catch (error) {
      elements.profileFeedback.dataset.state = "error";
      elements.profileFeedback.textContent = error instanceof Error
        ? error.message
        : "保存配置时发生未知错误";
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
    setCatalog,
    setStatus,
  };
}
