export function createSystemView(elements, { onBindingChanged }) {
  const homePlaceholder = "${SWAWKIT_HOME}";

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

  function render() {
    elements.systemDetail.hidden = false;
    elements.commandDetail.hidden = true;
    elements.selectionStatus.textContent = "已选择系统信息";
  }

  function renderBinding(binding) {
    elements.bindingState.dataset.state = binding.status;
    elements.bindingResolvedRoot.textContent = binding.resolvedTargetProjectRoot || "—";
    if (binding.targetProjectRoot) {
      elements.bindingTargetProjectRoot.value = binding.targetProjectRoot;
    } else if (!elements.bindingTargetProjectRoot.value) {
      elements.bindingTargetProjectRoot.value = homePlaceholder;
    }

    if (binding.status === "ready") {
      elements.bindingState.textContent = "目标项目已绑定";
    } else if (binding.status === "invalid") {
      elements.bindingState.textContent = binding.error || "绑定记录无效";
    } else {
      elements.bindingState.textContent = "尚未绑定目标项目";
    }
  }

  async function loadBinding() {
    elements.bindingState.dataset.state = "loading";
    elements.bindingState.textContent = "正在读取目标项目绑定…";
    try {
      const response = await fetch("/api/v1/binding", {
        cache: "no-store",
        headers: { Accept: "application/json" },
      });
      if (!response.ok) {
        throw new Error(`Host 返回 HTTP ${response.status}`);
      }
      renderBinding(await response.json());
    } catch (error) {
      elements.bindingState.dataset.state = "invalid";
      elements.bindingState.textContent = error instanceof Error
        ? error.message
        : "读取绑定时发生未知错误";
    }
  }

  async function saveBinding() {
    elements.bindingSaveButton.disabled = true;
    elements.bindingFeedback.dataset.state = "";
    elements.bindingFeedback.textContent = "正在保存…";
    try {
      const response = await fetch("/api/v1/binding", {
        method: "PUT",
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          targetProjectRoot: elements.bindingTargetProjectRoot.value,
        }),
      });
      const document = await response.json();
      if (!response.ok) {
        throw new Error(document.error || `Host 返回 HTTP ${response.status}`);
      }
      renderBinding(document);
      elements.bindingFeedback.textContent = "绑定已保存";
      await onBindingChanged();
    } catch (error) {
      elements.bindingFeedback.dataset.state = "error";
      elements.bindingFeedback.textContent = error instanceof Error
        ? error.message
        : "保存绑定时发生未知错误";
    } finally {
      elements.bindingSaveButton.disabled = false;
    }
  }

  return {
    loadBinding,
    render,
    saveBinding,
    setCatalog,
    setStatus,
  };
}
