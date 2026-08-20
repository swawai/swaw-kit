import { t } from "./i18n.js";

export const RUNTIME_UPDATE_REQUIRED_CODE = "runtimeUpdateRequired";
export const RUNTIME_GENERATION_UNAVAILABLE_CODE = "runtimeGenerationUnavailable";

export class RuntimeGenerationError extends Error {
  constructor(message, status, code) {
    super(message);
    this.name = "RuntimeGenerationError";
    this.status = status;
    this.code = code;
  }
}

export function isRuntimeGenerationCode(code) {
  return code === RUNTIME_UPDATE_REQUIRED_CODE
    || code === RUNTIME_GENERATION_UNAVAILABLE_CODE;
}

export function runtimeGenerationMessage(code) {
  if (code === RUNTIME_UPDATE_REQUIRED_CODE) {
    return t(
      "Runtime 已更新；请重新打开此 Entry 后再继续。",
      "The Runtime was updated; reopen this Entry before continuing.",
    );
  }
  if (code === RUNTIME_GENERATION_UNAVAILABLE_CODE) {
    return t(
      "无法确认当前 Runtime 版本；请重新打开此 Entry。",
      "The selected Runtime release cannot be verified; reopen this Entry.",
    );
  }
  return null;
}
