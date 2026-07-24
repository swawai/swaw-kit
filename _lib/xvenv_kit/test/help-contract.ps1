function Invoke-XvenvHelpTestEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Entry,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments
    )

    $PreviousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $Output = @(& $Entry @Arguments 2>&1)
        $ExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $PreviousPreference
    }
    return [pscustomobject]@{
        ExitCode = $ExitCode
        Text = [string]::Join("`n", [string[]]$Output)
    }
}

function Get-XvenvHelpSignatures {
    param([Parameter(Mandatory = $true)][string]$Text)

    $Signatures = foreach ($Line in $Text -split '\r?\n') {
        if ($Line -match '^  (?<signature>(?:\{\{COMMAND\}\}|\{\{SET_COMMAND\}\}).*?)\{\{ALIGN\}\}') {
            $Matches['signature']
        }
    }
    return @($Signatures | Sort-Object -Unique)
}

function Test-XvenvHelpContract {
    param(
        [Parameter(Mandatory = $true)][string]$CopiedCmdEntry,
        [Parameter(Mandatory = $true)][string]$CopiedPowerShellEntry,
        [Parameter(Mandatory = $true)][string]$CopiedToolbox
    )

    Write-Host '[TEST] Localized help contract'
    Assert-Equal `
        (ConvertTo-XvenvHelpLanguage 'zh-Hans-CN') `
        'zh-CN' `
        'Chinese language tags must normalize'
    Assert-Equal `
        (ConvertTo-XvenvHelpLanguage 'en-US') `
        'en' `
        'English language tags must normalize'
    Assert-True `
        ($null -eq (ConvertTo-XvenvHelpLanguage 'english')) `
        'language matching must reject prefix collisions'

    $EnglishTemplate = [IO.File]::ReadAllText(
        (Join-Path $KitRoot.FullName 'help\en.txt'),
        [Text.Encoding]::UTF8
    )
    $ChineseTemplate = [IO.File]::ReadAllText(
        (Join-Path $KitRoot.FullName 'help\zh-CN.txt'),
        [Text.Encoding]::UTF8
    )
    $SignatureDiff = @(
        Compare-Object `
            (Get-XvenvHelpSignatures $EnglishTemplate) `
            (Get-XvenvHelpSignatures $ChineseTemplate)
    )
    Assert-Equal `
        $SignatureDiff.Count `
        0 `
        'English and Chinese help must expose the same command signatures'

    $English = Invoke-XvenvHelpTestEntry `
        -Entry $CopiedPowerShellEntry `
        -Arguments @('--help', 'en')
    Assert-Equal $English.ExitCode 0 'PowerShell --help en must succeed'
    Assert-True `
        $English.Text.Contains('Portable project environments') `
        'English help must use the English template'
    Assert-True `
        $English.Text.Contains('xvenv set bun pwsh python go') `
        'help must derive the current public tool set from the catalog'
    Assert-True `
        $English.Text.Contains('xvenv link') `
        'help must document the explicit project-writing command'
    Assert-True `
        (-not $English.Text.Contains('{{')) `
        'rendered English help must not retain placeholders'
    Assert-True `
        (-not $English.Text.Contains("`n      ")) `
        'command descriptions must stay on the command line'
    Assert-True `
        ($English.Text.IndexOf('xvenv help zh') -lt $English.Text.IndexOf('xvenv help en')) `
        'English help must list the other language first'

    $Chinese = Invoke-XvenvHelpTestEntry `
        -Entry $CopiedCmdEntry `
        -Arguments @('help', 'zh')
    Assert-Equal $Chinese.ExitCode 0 'CMD help zh must succeed'
    Assert-True `
        ($Chinese.Text -match '\u9879\u76ee\u7ea7\u4fbf\u643a\u5f00\u53d1\u73af\u5883') `
        'Chinese help must use the Chinese template'
    Assert-True `
        ($Chinese.Text -match '"xvenv set" \u662f\u58f0\u660e\u5f0f\u547d\u4ee4') `
        'Chinese help must explain declarative set semantics'
    Assert-True `
        ($Chinese.Text.IndexOf('xvenv help en') -lt $Chinese.Text.IndexOf('xvenv help zh')) `
        'Chinese help must list the other language first'

    foreach ($Alias in @('-h', '/?')) {
        $AliasResult = Invoke-XvenvHelpTestEntry `
            -Entry $CopiedPowerShellEntry `
            -Arguments @($Alias, 'en')
        Assert-Equal $AliasResult.ExitCode 0 "$Alias must be a help alias"
        Assert-True `
            $AliasResult.Text.Contains('Portable project environments') `
            "$Alias must render help"
    }

    Assert-True `
        (-not [IO.Directory]::Exists((Join-Path $CopiedToolbox 'data'))) `
        'read-only help forms must not create xvenv data'

    $SettingsPath = Join-Path `
        $CopiedToolbox `
        'data\xvenv\settings\help-language.txt'
    $SavedLanguage = [Environment]::GetEnvironmentVariable(
        'XVENV_HELP_LANG',
        [EnvironmentVariableTarget]::Process
    )
    try {
        $SetEnglish = Invoke-XvenvHelpTestEntry `
            -Entry $CopiedPowerShellEntry `
            -Arguments @('help', 'default=en')
        Assert-Equal $SetEnglish.ExitCode 0 'setting a persistent default must succeed'
        Assert-True `
            ([IO.File]::Exists($SettingsPath)) `
            'the persistent default must be written under the central data root'
        Assert-Equal `
            ([IO.File]::ReadAllText($SettingsPath, [Text.Encoding]::UTF8)) `
            "en`r`n" `
            'the persisted language must use a small canonical value'

        $Configured = Invoke-XvenvHelpTestEntry `
            -Entry $CopiedPowerShellEntry `
            -Arguments @('--help')
        Assert-Equal $Configured.ExitCode 0 'persisted help language must succeed'
        Assert-True `
            $Configured.Text.Contains('Portable project environments') `
            'a later process must load the persisted default'

        $ExplicitOverride = Invoke-XvenvHelpTestEntry `
            -Entry $CopiedPowerShellEntry `
            -Arguments @('help', 'zh')
        Assert-Equal `
            $ExplicitOverride.ExitCode `
            0 `
            'an explicit language must override the persisted default'
        Assert-True `
            ($ExplicitOverride.Text -match '\u9879\u76ee\u7ea7\u4fbf\u643a\u5f00\u53d1\u73af\u5883') `
            'the explicit language override must select Chinese'

        $KnownTimestamp = [DateTime]::new(
            2002,
            3,
            4,
            5,
            6,
            7,
            [DateTimeKind]::Utc
        )
        [IO.File]::SetLastWriteTimeUtc($SettingsPath, $KnownTimestamp)
        $SetEnglishAgain = Invoke-XvenvHelpTestEntry `
            -Entry $CopiedPowerShellEntry `
            -Arguments @('help', 'default=en')
        Assert-Equal $SetEnglishAgain.ExitCode 0 'setting the same default must succeed'
        Assert-Equal `
            ([IO.File]::GetLastWriteTimeUtc($SettingsPath)) `
            $KnownTimestamp `
            'setting the same default must not rewrite its file'

        $env:XVENV_HELP_LANG = 'zh'
        $IgnoredEnvironment = Invoke-XvenvHelpTestEntry `
            -Entry $CopiedPowerShellEntry `
            -Arguments @('--help')
        Assert-Equal $IgnoredEnvironment.ExitCode 0 'ambient help variables must be ignored'
        Assert-True `
            $IgnoredEnvironment.Text.Contains('Portable project environments') `
            'the persisted setting must outrank the obsolete environment variable'

        $AliasMutation = Invoke-XvenvHelpTestEntry `
            -Entry $CopiedPowerShellEntry `
            -Arguments @('--help', 'default=zh')
        Assert-Equal $AliasMutation.ExitCode 1 'help aliases must stay read-only'
        Assert-Equal `
            ([IO.File]::ReadAllText($SettingsPath, [Text.Encoding]::UTF8)) `
            "en`r`n" `
            'a rejected alias mutation must preserve the persisted setting'

        $InvalidDefault = Invoke-XvenvHelpTestEntry `
            -Entry $CopiedPowerShellEntry `
            -Arguments @('help', 'default=english')
        Assert-Equal $InvalidDefault.ExitCode 1 'an invalid persistent language must fail'
        Assert-Equal `
            ([IO.File]::ReadAllText($SettingsPath, [Text.Encoding]::UTF8)) `
            "en`r`n" `
            'an invalid persistent language must preserve the current setting'

        $SetChinese = Invoke-XvenvHelpTestEntry `
            -Entry $CopiedPowerShellEntry `
            -Arguments @('help', 'default=zh')
        Assert-Equal $SetChinese.ExitCode 0 'changing the persisted default must succeed'
        $ConfiguredChinese = Invoke-XvenvHelpTestEntry `
            -Entry $CopiedPowerShellEntry `
            -Arguments @('--help')
        Assert-Equal `
            $ConfiguredChinese.ExitCode `
            0 `
            'the changed persisted default must remain readable'
        Assert-True `
            ($ConfiguredChinese.Text -match '\u9879\u76ee\u7ea7\u4fbf\u643a\u5f00\u53d1\u73af\u5883') `
            'a later process must load the changed persisted default'
    } finally {
        [Environment]::SetEnvironmentVariable(
            'XVENV_HELP_LANG',
            $SavedLanguage,
            [EnvironmentVariableTarget]::Process
        )
    }

    $InvalidExplicit = Invoke-XvenvHelpTestEntry `
        -Entry $CopiedPowerShellEntry `
        -Arguments @('help', 'english')
    Assert-Equal $InvalidExplicit.ExitCode 1 'invalid explicit help language must fail'
    Assert-True `
        $InvalidExplicit.Text.Contains('Unsupported help language') `
        'invalid explicit language must report the accepted languages'

    $ExtraArgument = Invoke-XvenvHelpTestEntry `
        -Entry $CopiedPowerShellEntry `
        -Arguments @('--help', 'en', 'extra')
    Assert-Equal $ExtraArgument.ExitCode 1 'help must reject extra arguments'
    Assert-True `
        $ExtraArgument.Text.Contains('Usage: xvenv --help [zh|en]') `
        'extra help arguments must report the supported syntax'

    $LinkExtraArgument = Invoke-XvenvHelpTestEntry `
        -Entry $CopiedPowerShellEntry `
        -Arguments @('link', 'extra')
    Assert-Equal $LinkExtraArgument.ExitCode 1 'link must reject extra arguments'
    Assert-True `
        $LinkExtraArgument.Text.Contains('Usage: xvenv link') `
        'invalid link arguments must report the supported syntax'

    Assert-True `
        (@(Get-ChildItem `
            -LiteralPath (Join-Path $CopiedToolbox 'data') `
            -Recurse `
            -File).Count -eq 1) `
        'the persistent language command must write only its settings file'
}
