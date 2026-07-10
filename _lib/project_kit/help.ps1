<#
.SYNOPSIS
  Print localized help for project_kit.
#>

param(
    [string]$CommandName = "project",
    [AllowNull()] [string]$Language
)

$ErrorActionPreference = "Stop"

try {
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = $utf8NoBom
    $OutputEncoding = $utf8NoBom
} catch {
}

$requestedLanguage = @($Language, $env:PROJECT_HELP_LANG, "zh-CN") |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -First 1
$requestedLanguage = $requestedLanguage.Trim()

if ($requestedLanguage -match '^zh(?:$|[-_])') {
    $language = "zh-CN"
} elseif ($requestedLanguage -match '^en(?:$|[-_])') {
    Write-Host ('[ERROR] 英文帮助尚未提供。请运行 "{0} --help" 查看中文帮助。' -f $CommandName)
    exit 1
} else {
    Write-Host "[ERROR] 不支持的帮助语言: $requestedLanguage"
    exit 1
}

$helpPath = Join-Path $PSScriptRoot "help\$language.txt"
if (-not (Test-Path -LiteralPath $helpPath -PathType Leaf)) {
    Write-Host "[ERROR] Help template not found: $helpPath"
    exit 1
}

try {
    $text = [System.IO.File]::ReadAllText($helpPath, [System.Text.Encoding]::UTF8)
} catch {
    Write-Host "[ERROR] Failed to read help template: $helpPath"
    Write-Host $_.Exception.Message
    exit 1
}

$text = $text.Replace("{{COMMAND}}", $CommandName)
Write-Host $text
exit 0
