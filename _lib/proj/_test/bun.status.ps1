[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ProjRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $ProjRoot '.dev\setup\_lib\bootstrap.ps1')
. (Join-Path $ProjRoot '_core\engine.ps1')
. (Join-Path $PSScriptRoot '_lib\bun-fixture.ps1')

$EnvironmentNames = @(
    'SWAWKIT_PROJ_PROTOCOL',
    'SWAWKIT_PROJ_ID',
    'SWAWKIT_PROJ_DIR',
    'SWAWKIT_PROJ_ACTION_ROOT',
    'SWAWKIT_PROJ_DATA_ROOT',
    'SWAWKIT_PROJ_ENTRY_COMMAND',
    'SWAWKIT_PROJ_ENTRY_FILE',
    'SWAWKIT_INVOCATION_DIR',
    'SWAWKIT_PROJ_BUN_MODE',
    'SWAWKIT_PROJ_BUN_VERSION',
    'SWAWKIT_PROJ_BUN_SHA256'
)
$EnvironmentSnapshot = Enter-ProjBunIsolatedEnvironment `
    -ProjectVariableNames $EnvironmentNames
$TestTemporaryBase = [IO.Path]::GetFullPath(
    (Join-Path $ProjRoot '..\..\data\_test')
)
[void][IO.Directory]::CreateDirectory($TestTemporaryBase)
$TemporaryRoot = Join-Path $TestTemporaryBase (
    "swawkit-proj-bun-status-$([Guid]::NewGuid().ToString('N'))"
)
$SystemPowerShell = Join-Path $env:SystemRoot (
    'System32\WindowsPowerShell\v1.0\powershell.exe'
)

try {
    $ProjectRoot = Join-Path $TemporaryRoot 'project'
    $ActionRoot = Join-Path $ProjectRoot '.swaw'
    [void][IO.Directory]::CreateDirectory($ActionRoot)
    $EntryFile = Join-Path $ProjectRoot 'entry.cmd'
    [IO.File]::WriteAllText($EntryFile, '@echo off')
    $DataRoot = Join-Path $TemporaryRoot 'data'
    Set-ProjBunProcessEnvironment -Values @{
        SWAWKIT_PROJ_PROTOCOL = '1'
        SWAWKIT_PROJ_ID = 'bun-status'
        SWAWKIT_PROJ_DIR = $ProjectRoot
        SWAWKIT_PROJ_ACTION_ROOT = $ActionRoot
        SWAWKIT_PROJ_DATA_ROOT = $DataRoot
        SWAWKIT_PROJ_ENTRY_COMMAND = 'swawkit'
        SWAWKIT_PROJ_ENTRY_FILE = $EntryFile
        SWAWKIT_INVOCATION_DIR = $ProjectRoot
        SWAWKIT_PROJ_BUN_MODE = 'managed'
        SWAWKIT_PROJ_BUN_VERSION = '1.2.15'
        SWAWKIT_PROJ_BUN_SHA256 = ''
    }

    $Context = New-ProjDevContextFromEnvironment
    $Definition = Get-ProjDevBunDefinition
    $Definition.Sha256 = 'f' * 64
    $Definition.Verification = 'github'
    $InstallRoot = Get-ProjDevInstallRoot `
        -Context $Context `
        -Definition $Definition
    [void][IO.Directory]::CreateDirectory($InstallRoot)
    New-ProjBunFixtureExecutable `
        -Path (Join-Path $InstallRoot 'bun.exe') `
        -Version '1.2.15'
    [IO.File]::WriteAllText(
        (Join-Path $InstallRoot 'bunx.cmd'),
        "@echo off`r`n`"%~dp0bun.exe`" x %*`r`n",
        [Text.UTF8Encoding]::new($false)
    )
    Write-ProjDevInstallMetadata `
        -Definition $Definition `
        -InstallRoot $InstallRoot

    $StatusResult = Invoke-ProjBunMainFixture `
        -PowerShell $SystemPowerShell `
        -KernelRoot $ProjRoot `
        -WorkingDirectory $ProjectRoot `
        -Arguments @('.dev.status')
    Assert-ProjBunTest `
        -Condition (
            $StatusResult.ExitCode -eq 0 -and
            $StatusResult.Output -like '*[[]READY[]]*bun 1.2.15*upstream*' -and
            $StatusResult.Output -like '*GitHub Release digest*' -and
            $StatusResult.Output -like '*SWAWKIT_PROJ_BUN_SHA256*'
        ) `
        -Message ".dev.status did not report upstream trust: $($StatusResult.Output)"

    $SetupResult = Invoke-ProjBunMainFixture `
        -PowerShell $SystemPowerShell `
        -KernelRoot $ProjRoot `
        -WorkingDirectory $ProjectRoot `
        -Arguments @('.dev.setup')
    Assert-ProjBunTest `
        -Condition (
            $SetupResult.ExitCode -eq 0 -and
            $SetupResult.Output -like '*Bun 1.2.15 is ready*' -and
            $SetupResult.Output -like '*GitHub Release digest*' -and
            [IO.File]::Exists($Context.EnvCmdPath) -and
            [IO.File]::Exists($Context.EnvPs1Path)
        ) `
        -Message ".dev.setup did not preserve non-blocking trust: $($SetupResult.Output)"

    $PinnedDataRoot = Join-Path $TemporaryRoot 'pinned missing'
    $env:SWAWKIT_PROJ_DATA_ROOT = $PinnedDataRoot
    $env:SWAWKIT_PROJ_BUN_SHA256 = 'e' * 64
    $PinnedStatus = Invoke-ProjBunMainFixture `
        -PowerShell $SystemPowerShell `
        -KernelRoot $ProjRoot `
        -WorkingDirectory $ProjectRoot `
        -Arguments @('.dev.status')
    Assert-ProjBunTest `
        -Condition (
            $PinnedStatus.ExitCode -eq 0 -and
            $PinnedStatus.Output -like '*[[]MISSING[]]*bun 1.2.15*pinned*' -and
            $PinnedStatus.Output -notlike '*WARNING*' -and
            -not [IO.Directory]::Exists($PinnedDataRoot)
        ) `
        -Message ".dev.status was not read-only for pinned state: $($PinnedStatus.Output)"

    Write-Host '[PASS] Proj Bun development status test' `
        -ForegroundColor Green
} finally {
    Exit-ProjBunIsolatedEnvironment -Snapshot $EnvironmentSnapshot
    $ResolvedTemporaryRoot = [IO.Path]::GetFullPath($TemporaryRoot)
    $SystemTemporaryRoot = [IO.Path]::GetFullPath(
        $TestTemporaryBase
    ).TrimEnd('\') + '\'
    if ($ResolvedTemporaryRoot.StartsWith(
        $SystemTemporaryRoot,
        [StringComparison]::OrdinalIgnoreCase
    ) -and
        [IO.Path]::GetFileName($ResolvedTemporaryRoot).StartsWith(
            'swawkit-proj-bun-status-',
            [StringComparison]::Ordinal
        ) -and
        [IO.Directory]::Exists($ResolvedTemporaryRoot)) {
        Remove-Item -LiteralPath $ResolvedTemporaryRoot -Recurse -Force
    }
}
