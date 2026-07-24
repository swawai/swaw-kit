Set-StrictMode -Version 2.0

function ConvertTo-XvenvHelpLanguage {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }
    $Normalized = $Value.Trim()
    if ($Normalized -match '^zh(?:$|[-_])') {
        return 'zh-CN'
    }
    if ($Normalized -match '^en(?:$|[-_])') {
        return 'en'
    }
    return $null
}

function Get-XvenvDefaultHelpLanguagePath {
    param([Parameter(Mandatory = $true)][object]$Context)

    return Join-Path $Context.DataRoot 'settings\help-language.txt'
}

function Get-XvenvPersistedHelpLanguage {
    param([Parameter(Mandatory = $true)][object]$Context)

    $Path = Get-XvenvDefaultHelpLanguagePath -Context $Context
    if (-not [IO.File]::Exists($Path)) {
        return $null
    }
    $Value = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8).Trim()
    $Language = ConvertTo-XvenvHelpLanguage $Value
    if ($null -eq $Language) {
        throw "The saved xvenv help language is invalid: $Path. Run xvenv help default=en or xvenv help default=zh."
    }
    return $Language
}

function Get-XvenvPreferredHelpLanguage {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [AllowNull()][string]$ExplicitLanguage = $null
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitLanguage)) {
        $KnownLanguage = ConvertTo-XvenvHelpLanguage $ExplicitLanguage
        if ($null -eq $KnownLanguage) {
            throw "Unsupported help language '$ExplicitLanguage'. Use zh or en."
        }
        return $KnownLanguage
    }

    $PersistedLanguage = Get-XvenvPersistedHelpLanguage -Context $Context
    if ($null -ne $PersistedLanguage) {
        return $PersistedLanguage
    }

    foreach ($EnvironmentValue in @($env:LC_ALL, $env:LC_MESSAGES, $env:LANG)) {
        $KnownLanguage = ConvertTo-XvenvHelpLanguage $EnvironmentValue
        if ($null -ne $KnownLanguage) {
            return $KnownLanguage
        }
    }

    try {
        $UserLanguage = @(Get-WinUserLanguageList | Select-Object -First 1)[0]
        if ($null -ne $UserLanguage) {
            $KnownLanguage = ConvertTo-XvenvHelpLanguage $UserLanguage.LanguageTag
            if ($null -ne $KnownLanguage) {
                return $KnownLanguage
            }
        }
    } catch {
    }

    foreach ($CultureName in @(
        [Globalization.CultureInfo]::CurrentUICulture.Name,
        [Globalization.CultureInfo]::CurrentCulture.Name,
        [Globalization.CultureInfo]::InstalledUICulture.Name
    )) {
        $KnownLanguage = ConvertTo-XvenvHelpLanguage $CultureName
        if ($null -ne $KnownLanguage) {
            return $KnownLanguage
        }
    }
    return 'en'
}

function Get-XvenvHelpText {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [AllowNull()][string]$Language = $null
    )

    $ResolvedLanguage = Get-XvenvPreferredHelpLanguage `
        -Context $Context `
        -ExplicitLanguage $Language
    $HelpRoot = Get-XvenvFullPath (Join-Path $PSScriptRoot '..\help')
    $HelpPath = Join-Path $HelpRoot "$ResolvedLanguage.txt"
    if (-not [IO.File]::Exists($HelpPath)) {
        throw "xvenv help template is missing: $HelpPath"
    }

    $Text = [IO.File]::ReadAllText($HelpPath, [Text.Encoding]::UTF8).
        Replace('{{COMMAND}}', 'xvenv').
        Replace('{{SET_COMMAND}}', (Get-XvenvSetCommandExample $Context.Catalog))
    return Format-XvenvHelpRows -Text $Text
}

function Format-XvenvHelpRows {
    param([Parameter(Mandatory = $true)][string]$Text)

    $Marker = '{{ALIGN}}'
    $Lines = [regex]::Split($Text, '\r?\n')
    $Rows = [Collections.Generic.List[object]]::new()
    $Width = 0
    for ($Index = 0; $Index -lt $Lines.Count; $Index++) {
        $MarkerIndex = $Lines[$Index].IndexOf(
            $Marker,
            [StringComparison]::Ordinal
        )
        if ($MarkerIndex -lt 0) {
            continue
        }
        $Command = $Lines[$Index].Substring(0, $MarkerIndex).TrimEnd()
        $Description = $Lines[$Index].
            Substring($MarkerIndex + $Marker.Length).
            TrimStart()
        $Width = [Math]::Max($Width, $Command.Length)
        [void]$Rows.Add([pscustomobject]@{
            Index = $Index
            Command = $Command
            Description = $Description
        })
    }

    foreach ($Row in $Rows) {
        $Lines[$Row.Index] = $Row.Command.PadRight($Width + 2) + $Row.Description
    }
    return [string]::Join("`r`n", [string[]]$Lines)
}

function Invoke-XvenvHelp {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [AllowNull()][string]$Language = $null
    )

    $Text = Get-XvenvHelpText -Context $Context -Language $Language
    [Console]::Out.Write($Text)
    return 0
}

function Set-XvenvDefaultHelpLanguage {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][string]$Language
    )

    $ResolvedLanguage = ConvertTo-XvenvHelpLanguage $Language
    if ($null -eq $ResolvedLanguage) {
        throw "Unsupported help language '$Language'. Use zh or en."
    }
    $StoredLanguage = if ($ResolvedLanguage -eq 'zh-CN') { 'zh' } else { 'en' }
    $Content = "$StoredLanguage`r`n"
    $Path = Get-XvenvDefaultHelpLanguagePath -Context $Context
    $Changed = $true
    if ([IO.File]::Exists($Path)) {
        $Changed = [IO.File]::ReadAllText(
            $Path,
            [Text.Encoding]::UTF8
        ) -cne $Content
    }
    if ($Changed) {
        Write-XvenvTextAtomic `
            -Path $Path `
            -Content $Content `
            -Encoding ([Text.UTF8Encoding]::new($false))
        Write-Host "xvenv default help language set: $StoredLanguage" -ForegroundColor Green
    } else {
        Write-Host "xvenv default help language is already $StoredLanguage." -ForegroundColor Green
    }
    return 0
}
