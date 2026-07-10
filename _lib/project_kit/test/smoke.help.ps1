[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
$entryFile = Join-Path $repoRoot "proj1.cmd"

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-Captured {
    param(
        [string]$File,
        [string[]]$CommandArgs,
        [int]$ExpectedExitCode,
        [string]$Label
    )

    $output = (& $File @CommandArgs 2>&1 | Out-String)
    $exitCode = $LASTEXITCODE
    Assert-True ($exitCode -eq $ExpectedExitCode) "$Label failed: expected exit code $ExpectedExitCode, got $exitCode. Output: $output"
    return $output
}

function Set-EntryLine {
    param(
        [string]$Content,
        [string]$Name,
        [string]$Value
    )

    $pattern = '(?m)^(?::: )?set "' + [regex]::Escape($Name) + '=.*"\r?$'
    Assert-True ($Content -match $pattern) "proj1.cmd should declare $Name."

    $line = 'set "' + $Name + '=' + $Value + '"'
    return [regex]::Replace(
        $Content,
        $pattern,
        [System.Text.RegularExpressions.MatchEvaluator] { param($match) $line }
    )
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("project-kit-help-" + [guid]::NewGuid().ToString("N"))
$entryName = "proj1.help-smoke-" + [guid]::NewGuid().ToString("N")
$smokeEntry = Join-Path $repoRoot "$entryName.cmd"
$oldLanguage = $env:PROJECT_HELP_LANG

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $missingProject = Join-Path $tempRoot "missing-project"
    $dataRoot = Join-Path $tempRoot "data"

    $content = [System.IO.File]::ReadAllText($entryFile)
    $content = Set-EntryLine $content "PROJECT_DIR" $missingProject
    $content = Set-EntryLine $content "PROJECT_DATA_ROOT" $dataRoot
    $crlf = [string][char]13 + [char]10
    $content = [regex]::Replace($content, '\r?\n', $crlf)
    [System.IO.File]::WriteAllText($smokeEntry, $content, [System.Text.UTF8Encoding]::new($false))

    $env:PROJECT_HELP_LANG = $null
    $cases = @(
        @{ Args = [string[]]@("--help"); Label = "--help" },
        @{ Args = [string[]]@("-h"); Label = "-h" },
        @{ Args = [string[]]@("/?"); Label = "/?" },
        @{ Args = [string[]]@(".help"); Label = ".help" },
        @{ Args = [string[]]@(".help", "zh"); Label = ".help zh" },
        @{ Args = [string[]]@(".help", "zh-CN"); Label = ".help zh-CN" }
    )

    foreach ($case in $cases) {
        $output = Invoke-Captured $smokeEntry $case.Args 0 $case.Label
        Assert-True ($output.Contains("Project Kit: 项目目录绑定的便携工作台")) "$($case.Label) should show the Chinese title."
        Assert-True ($output.Contains($entryName)) "$($case.Label) should use the actual entry name."
        Assert-True (-not $output.Contains("{{COMMAND}}")) "$($case.Label) should replace template placeholders."
    }

    $help = Invoke-Captured $smokeEntry @("--help") 0 "help contract"
    foreach ($required in @(
        "项目管理:",
        "环境管理:",
        "项目命令:",
        ".doctor",
        ".env module gh install",
        "git ...",
        "仅帮助命令已实现",
        "不修改系统 PATH"
    )) {
        Assert-True ($help.Contains($required)) "help should contain: $required"
    }

    Assert-True (-not (Test-Path -LiteralPath $missingProject)) "help should not create PROJECT_DIR."
    Assert-True (-not (Test-Path -LiteralPath $dataRoot)) "help should not create PROJECT_DATA_ROOT."

    $env:PROJECT_HELP_LANG = "zh-Hans"
    $null = Invoke-Captured $smokeEntry @("--help") 0 "PROJECT_HELP_LANG zh-Hans"

    $env:PROJECT_HELP_LANG = "en"
    $englishFromEnvironment = Invoke-Captured $smokeEntry @("--help") 1 "PROJECT_HELP_LANG en"
    Assert-True ($englishFromEnvironment.Contains("英文帮助尚未提供")) "PROJECT_HELP_LANG=en should explain that English help is unavailable."
    $null = Invoke-Captured $smokeEntry @(".help", "zh") 0 "explicit language overrides environment"

    $env:PROJECT_HELP_LANG = "zh-CN"
    $englishExplicit = Invoke-Captured $smokeEntry @("--help", "en-US") 1 "--help en-US"
    Assert-True ($englishExplicit.Contains("英文帮助尚未提供")) "explicit English should override PROJECT_HELP_LANG."

    $null = Invoke-Captured $smokeEntry @("--help", "zh-Hant") 0 "--help zh-Hant"

    $unknown = Invoke-Captured $smokeEntry @(".help", "fr") 1 "unknown language"
    Assert-True ($unknown.Contains("不支持的帮助语言")) "unknown languages should be rejected explicitly."

    $notImplemented = Invoke-Captured $smokeEntry @(".info") 1 "non-help command"
    Assert-True ($notImplemented.Contains("当前尚未实现")) "non-help commands should not report false success."
    Assert-True ($notImplemented.Contains("$entryName --help")) "non-help errors should point to the actual entry command."
} finally {
    $env:PROJECT_HELP_LANG = $oldLanguage
    Remove-Item -LiteralPath $smokeEntry -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
