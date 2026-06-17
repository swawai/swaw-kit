<#
.SYNOPSIS
  Dispatcher for WSL resource entry files.
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = "Stop"

$libDir = Join-Path $PSScriptRoot "lib"
. (Join-Path $libDir "common.ps1")
. (Join-Path $libDir "ini.ps1")
. (Join-Path $libDir "config.ps1")
. (Join-Path $libDir "wsl-native.ps1")
. (Join-Path $libDir "user.ps1")
. (Join-Path $libDir "editor.ps1")
. (Join-Path $libDir "systemd.ps1")
. (Join-Path $libDir "network.ps1")
. (Join-Path $libDir "ssh.ps1")
. (Join-Path $libDir "control.ps1")

Initialize-ConsoleEncoding

$script:Config = New-WslKitConfig
if (-not (Test-WslKitConfig $script:Config)) {
    exit 1
}

if ($null -eq $Arguments) {
    $Arguments = @()
}

if ($Arguments.Count -eq 0) {
    $Arguments = Get-KitArgumentsFromEnvironment
}

$Arguments = Trim-TrailingEmptyArguments $Arguments

if ($Arguments.Count -eq 0) {
    exit (Invoke-WslShell)
}

$verb = $Arguments[0].ToLowerInvariant()

switch ($verb) {
    { $_ -in @("-h", "--help", "/?") } {
        & PowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "help.ps1") -CommandName $script:Config.CommandName
        exit $LASTEXITCODE
    }
    "status" {
        exit (Show-WslResourceStatus)
    }
    "code" {
        exit (Open-Editor "code" (Get-Slice $Arguments 1))
    }
    "cursor" {
        exit (Open-Editor "cursor" (Get-Slice $Arguments 1))
    }
    "ctl" {
        exit (Invoke-Control (Get-Slice $Arguments 1) $verb)
    }
    default {
        exit (Invoke-WslNativePassthrough $Arguments)
    }
}
