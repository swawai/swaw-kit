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
. (Join-Path $libDir "config.ps1")
. (Join-Path $libDir "wsl-native.ps1")
. (Join-Path $libDir "user.ps1")
. (Join-Path $libDir "install-fallback.ps1")
. (Join-Path $libDir "editor.ps1")
. (Join-Path $libDir "systemd.ps1")
. (Join-Path $libDir "port.ps1")
. (Join-Path $libDir "ssh.ps1")
. (Join-Path $libDir "control.ps1")

Initialize-ConsoleEncoding
Import-WslEntryFileEnvironment

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

if ($Arguments.Count -eq 0) {
    exit (Invoke-WslShell)
}

function Get-HelpLanguageArgument {
    param([string[]]$Items)

    if ($null -eq $Items -or $Items.Count -lt 2) {
        return $null
    }

    $candidate = $Items[1]
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return $null
    }

    if ($candidate.Trim() -match '^(zh($|[-_])|en($|[-_]))') {
        return $candidate
    }

    return $null
}

function Invoke-KitHelp {
    param([string[]]$Items)

    $helpArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "help.ps1"), "-CommandName", $script:Config.CommandName, "-EntryFileName", $script:Config.EntryFileName)
    $helpLanguage = Get-HelpLanguageArgument $Items
    if ($helpLanguage) {
        $helpArgs += @("-Language", $helpLanguage)
    }

    & PowerShell @helpArgs
}

$verb = $Arguments[0].ToLowerInvariant()

switch ($verb) {
    { $_ -in @("-h", "--help", "/?") } {
        Invoke-KitHelp $Arguments
        exit $LASTEXITCODE
    }
    { $_.StartsWith(".") } {
        $toolVerb = $_.Substring(1)
        $toolArgs = @(Get-Slice $Arguments 1)

        switch ($toolVerb) {
            "" {
                exit (Invoke-WslNativePassthrough $Arguments)
            }
            "help" {
                Invoke-KitHelp $Arguments
                exit $LASTEXITCODE
            }
            "status" {
                exit (Invoke-Status $toolArgs)
            }
            "doctor" {
                exit (Invoke-WslDoctor $toolArgs)
            }
            "code" {
                exit (Open-Editor "code" $toolArgs)
            }
            "cursor" {
                exit (Open-Editor "cursor" $toolArgs)
            }
            "vm" {
                exit (Invoke-VmControl $toolArgs ".vm")
            }
            { $_ -in @("t", "install", "backup", "dir", "alive", "port", "user", "sshd", "systemd", "delete", "relocate") } {
                exit (Invoke-InstanceManagementCommand (@($toolVerb) + $toolArgs))
            }
            default {
                exit (Invoke-WslNativePassthrough $Arguments)
            }
        }
    }
    default {
        exit (Invoke-WslNativePassthrough $Arguments)
    }
}
