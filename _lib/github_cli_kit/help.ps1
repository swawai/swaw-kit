param(
    [string]$CommandName = 'gh_identity',
    [string]$Language = ''
)

$ErrorActionPreference = 'Stop'

try {
    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    [Console]::OutputEncoding = $utf8NoBom
    $OutputEncoding = $utf8NoBom
} catch {
}

function Convert-ToKnownLanguage {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    if ($Value.Trim() -match '^zh(?:$|[-_])') { return 'zh-CN' }
    if ($Value.Trim() -match '^en(?:$|[-_])') { return 'en' }
    return $null
}

function Get-PreferredLanguage {
    foreach ($override in @($Language, $env:GH_ID_HELP_LANG)) {
        if (-not [string]::IsNullOrWhiteSpace($override)) {
            $known = Convert-ToKnownLanguage $override
            if ($known) { return $known }
            throw "Unsupported help language '$override'. Use zh or en."
        }
    }
    foreach ($candidate in @(
        $env:LC_ALL,
        $env:LC_MESSAGES,
        $env:LANG,
        [Globalization.CultureInfo]::CurrentCulture.Name,
        [Globalization.CultureInfo]::CurrentUICulture.Name
    )) {
        $known = Convert-ToKnownLanguage $candidate
        if ($known) { return $known }
    }
    return 'en'
}

try {
    $helpPath = Join-Path (Join-Path $PSScriptRoot 'help') "$(Get-PreferredLanguage).txt"
    if (-not [IO.File]::Exists($helpPath)) {
        throw "Help template not found: $helpPath"
    }
    $text = [IO.File]::ReadAllText($helpPath, [Text.Encoding]::UTF8)
    Write-Host $text.Replace('{{COMMAND}}', $CommandName)
    exit 0
} catch {
    Write-Host "[ERROR] $($_.Exception.Message)"
    exit 1
}
