<#
.SYNOPSIS
  Print localized help for ssh_remote_kit.
#>

param(
    [string]$CommandName = "remote_kit"
)

$ErrorActionPreference = "Stop"

try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [Console]::OutputEncoding = $utf8NoBom
    $OutputEncoding = $utf8NoBom
} catch {
}

function Convert-ToKnownHelpLanguage {
    param([AllowNull()] [string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $normalized = $Value.Trim()
    if ($normalized -match '^(zh|zh[-_])') {
        return "zh-CN"
    }

    if ($normalized -match '^(en|en[-_])') {
        return "en"
    }

    return $null
}

function Get-PreferredHelpLanguage {
    foreach ($override in @($env:REMOTE_KIT_HELP_LANG, $env:REMOTE_KIT_LANG)) {
        if (-not [string]::IsNullOrWhiteSpace($override)) {
            $language = Convert-ToKnownHelpLanguage $override
            if ($language) {
                return $language
            }

            return "en"
        }
    }

    foreach ($envCandidate in @($env:LC_ALL, $env:LC_MESSAGES, $env:LANG)) {
        $language = Convert-ToKnownHelpLanguage $envCandidate
        if ($language) {
            return $language
        }
    }

    try {
        $userLanguage = @(Get-WinUserLanguageList | Select-Object -First 1)[0]
        if ($null -ne $userLanguage) {
            $language = Convert-ToKnownHelpLanguage $userLanguage.LanguageTag
            if ($language) {
                return $language
            }
        }
    } catch {
    }

    $systemLocale = $null
    try {
        $systemLocale = (Get-WinSystemLocale).Name
    } catch {
    }

    $candidates = @(
        [System.Globalization.CultureInfo]::CurrentCulture.Name,
        (Get-Culture).Name,
        [System.Globalization.CultureInfo]::InstalledUICulture.Name,
        $systemLocale,
        [System.Globalization.CultureInfo]::CurrentUICulture.Name,
        (Get-UICulture).Name,
        $env:LC_ALL,
        $env:LC_MESSAGES,
        $env:LANG
    )

    foreach ($candidate in $candidates) {
        try {
            $language = Convert-ToKnownHelpLanguage $candidate
            if ($language) {
                return $language
            }
        } catch {
        }
    }

    return "en"
}

$helpDir = Join-Path $PSScriptRoot "help"
$language = Get-PreferredHelpLanguage
$helpPath = Join-Path $helpDir "$language.txt"

if (-not (Test-Path -LiteralPath $helpPath -PathType Leaf)) {
    $helpPath = Join-Path $helpDir "en.txt"
}

if (-not (Test-Path -LiteralPath $helpPath -PathType Leaf)) {
    Write-Host "[ERROR] Help template not found: $helpPath"
    exit 1
}

$text = [System.IO.File]::ReadAllText($helpPath, [System.Text.Encoding]::UTF8)
$text = $text.Replace("{{COMMAND}}", $CommandName)
Write-Host $text
exit 0
