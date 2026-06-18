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

function Invoke-ControlLayerCommandHint {
    param([string[]]$Items)

    if ($null -eq $Items -or $Items.Count -eq 0 -or [string]::IsNullOrWhiteSpace($Items[0])) {
        return $null
    }

    $helpPath = Join-Path $PSScriptRoot "help\zh-CN.txt"
    if (-not (Test-Path -LiteralPath $helpPath -PathType Leaf)) {
        Write-Fail "Control command hint source not found: $helpPath"
        return 1
    }

    try {
        $lines = [System.IO.File]::ReadAllLines($helpPath)
    } catch {
        Write-Fail "Failed to read control command hint source: $helpPath"
        Write-Fail $_.Exception.Message
        return 1
    }

    $target = $Items[0].ToLowerInvariant()
    $candidateCount = 0
    $suggestionKeys = New-Object System.Collections.Generic.HashSet[string]
    $allSuggestions = New-Object System.Collections.ArrayList

    function Test-ControlHintFixedToken {
        param(
            [string]$Token,
            [switch]$IsFirst
        )

        if ([string]::IsNullOrWhiteSpace($Token)) {
            return $false
        }

        if ($Token -notmatch '^-?[A-Za-z0-9_.-]+$') {
            return $false
        }

        if (-not $IsFirst -and $Token.StartsWith("-")) {
            return $false
        }

        if ($Token -match '^\d+$') {
            return $false
        }

        if ($Token -match '[:\\/\{\}<>\[\]\*]') {
            return $false
        }

        return $true
    }

    foreach ($line in $lines) {
        if ($line -notmatch '^\s*\{\{COMMAND\}\}\s+(ctl|vm)\s+(.+?)(?:\s{2,}.*)?$') {
            continue
        }

        $layer = $Matches[1].ToLowerInvariant()
        $tokens = @($Matches[2].Trim() -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($tokens.Count -eq 0) {
            continue
        }

        $prefix = New-Object System.Collections.ArrayList
        for ($i = 0; $i -lt $tokens.Count; $i++) {
            if (-not (Test-ControlHintFixedToken -Token $tokens[$i] -IsFirst:($i -eq 0))) {
                break
            }

            [void]$prefix.Add($tokens[$i])
        }

        if ($prefix.Count -eq 0) {
            continue
        }

        $candidateCount += 1
        $prefixMatchesTarget = $false
        foreach ($item in @($prefix)) {
            if ($item.ToLowerInvariant() -eq $target) {
                $prefixMatchesTarget = $true
                break
            }
        }

        if (-not $prefixMatchesTarget) {
            continue
        }

        $prefixKey = (@($prefix) | ForEach-Object { $_.ToLowerInvariant() }) -join " "
        $key = "$layer`0$prefixKey"
        if ($suggestionKeys.Add($key)) {
            [void]$allSuggestions.Add([pscustomobject]@{
                Layer  = $layer
                Prefix = @($prefix)
            })
        }
    }

    if ($candidateCount -eq 0) {
        Write-Fail "No ctl/vm command hints found in help template: $helpPath"
        Write-Fail "Expected lines like: {{COMMAND}} ctl install"
        return 1
    }

    $exactSuggestions = @($allSuggestions | Where-Object { $_.Prefix.Count -eq 1 -and $_.Prefix[0].ToLowerInvariant() -eq $target })
    $suggestions = if ($exactSuggestions.Count -gt 0) { $exactSuggestions } else { @($allSuggestions) }

    if ($suggestions.Count -eq 0) {
        return $null
    }

    Write-Fail "Unknown top-level command: $($Items[0])"
    Write-Fail "It looks like a control-layer subcommand. Did you mean:"
    foreach ($suggestion in $suggestions) {
        $suggestedArgs = New-Object System.Collections.ArrayList
        [void]$suggestedArgs.Add($suggestion.Layer)
        foreach ($item in @($suggestion.Prefix)) {
            [void]$suggestedArgs.Add($item)
        }
        if ($suggestion.Prefix.Count -eq 1) {
            foreach ($item in (Get-Slice $Items 1)) {
                [void]$suggestedArgs.Add($item)
            }
        }

        Write-Fail "  $(Format-CommandLine $script:Config.CommandName @($suggestedArgs))"
    }

    $passthroughArgs = New-Object System.Collections.ArrayList
    [void]$passthroughArgs.Add("--")
    foreach ($item in $Items) {
        [void]$passthroughArgs.Add($item)
    }

    Write-Fail "To run it inside Linux, use:"
    Write-Fail "  $(Format-CommandLine $script:Config.CommandName @($passthroughArgs))"
    return 1
}

$verb = $Arguments[0].ToLowerInvariant()

switch ($verb) {
    { $_ -in @("-h", "--help", "/?") } {
        $helpArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "help.ps1"), "-CommandName", $script:Config.CommandName)
        $helpLanguage = Get-HelpLanguageArgument $Arguments
        if ($helpLanguage) {
            $helpArgs += @("-Language", $helpLanguage)
        }

        & PowerShell @helpArgs
        exit $LASTEXITCODE
    }
    "status" {
        exit (Invoke-Status (Get-Slice $Arguments 1))
    }
    "doctor" {
        exit (Invoke-WslDoctor (Get-Slice $Arguments 1))
    }
    "code" {
        exit (Open-Editor "code" (Get-Slice $Arguments 1))
    }
    "cursor" {
        exit (Open-Editor "cursor" (Get-Slice $Arguments 1))
    }
    "vm" {
        exit (Invoke-VmControl (Get-Slice $Arguments 1) $verb)
    }
    "ctl" {
        exit (Invoke-Control (Get-Slice $Arguments 1) $verb)
    }
    default {
        $hintExitCode = Invoke-ControlLayerCommandHint $Arguments
        if ($null -ne $hintExitCode) {
            exit $hintExitCode
        }

        exit (Invoke-WslNativePassthrough $Arguments)
    }
}
