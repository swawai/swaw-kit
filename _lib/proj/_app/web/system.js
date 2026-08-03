export function createSystemView(elements) {
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

  return {
    render,
    setCatalog,
    setStatus,
  };
}
