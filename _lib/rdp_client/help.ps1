[CmdletBinding()]
param(
    [string]$CommandName = 'rdp',
    [AllowNull()][AllowEmptyString()][string]$Language
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function ConvertTo-RdpClientHelpLanguage {
    param([AllowNull()][AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }
    $Normalized = $Value.Trim()
    if ($Normalized -match '^(?i:zh)(?:$|[-_])') {
        return 'zh-CN'
    }
    if ($Normalized -match '^(?i:en)(?:$|[-_])') {
        return 'en'
    }
    return $null
}

function Get-RdpClientHelpLanguage {
    param([AllowNull()][AllowEmptyString()][string]$ExplicitLanguage)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitLanguage)) {
        $Resolved = ConvertTo-RdpClientHelpLanguage -Value $ExplicitLanguage
        return $(if ($null -eq $Resolved) { 'en' } else { $Resolved })
    }
    if (-not [string]::IsNullOrWhiteSpace($env:RDP_HELP_LANG)) {
        $Resolved = ConvertTo-RdpClientHelpLanguage -Value $env:RDP_HELP_LANG
        return $(if ($null -eq $Resolved) { 'en' } else { $Resolved })
    }

    foreach ($EnvironmentCandidate in @($env:LC_ALL, $env:LC_MESSAGES, $env:LANG)) {
        $Resolved = ConvertTo-RdpClientHelpLanguage -Value $EnvironmentCandidate
        if ($null -ne $Resolved) {
            return $Resolved
        }
    }
    try {
        $UserLanguage = @(Get-WinUserLanguageList | Select-Object -First 1)[0]
        if ($null -ne $UserLanguage) {
            $Resolved = ConvertTo-RdpClientHelpLanguage -Value $UserLanguage.LanguageTag
            if ($null -ne $Resolved) {
                return $Resolved
            }
        }
    } catch {
    }

    $Candidates = @(
        [Globalization.CultureInfo]::CurrentCulture.Name,
        [Globalization.CultureInfo]::InstalledUICulture.Name,
        [Globalization.CultureInfo]::CurrentUICulture.Name
    )
    foreach ($Candidate in $Candidates) {
        $Resolved = ConvertTo-RdpClientHelpLanguage -Value $Candidate
        if ($null -ne $Resolved) {
            return $Resolved
        }
    }
    return 'en'
}

try {
    $Utf8NoBom = New-Object Text.UTF8Encoding($false)
    [Console]::OutputEncoding = $Utf8NoBom
    $OutputEncoding = $Utf8NoBom

    $ResolvedLanguage = Get-RdpClientHelpLanguage -ExplicitLanguage $Language
    $HelpPath = Join-Path $PSScriptRoot "help\$ResolvedLanguage.txt"
    if (-not [IO.File]::Exists($HelpPath)) {
        $HelpPath = Join-Path $PSScriptRoot 'help\en.txt'
    }
    if (-not [IO.File]::Exists($HelpPath)) {
        throw "Help template not found: $HelpPath"
    }

    $Text = [IO.File]::ReadAllText($HelpPath, [Text.Encoding]::UTF8)
    $Text = $Text.Replace('{{COMMAND}}', $CommandName)
    Write-Host $Text
    exit 0
} catch {
    [Console]::Error.WriteLine("[ERROR] $($_.Exception.Message)")
    exit 1
}
