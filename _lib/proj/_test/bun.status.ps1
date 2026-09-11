[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$DevPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Invoke-ProjStatusToolchainFixture {
    param([Parameter(Mandatory = $true)][string]$Executable)

    $Info = [Diagnostics.ProcessStartInfo]::new()
    $Info.FileName = $Executable
    $Info.Arguments = 'command-v1 .dev/status'
    $Info.UseShellExecute = $false
    $Info.CreateNoWindow = $true
    $Info.RedirectStandardOutput = $true
    $Info.RedirectStandardError = $true
    $Process = [Diagnostics.Process]::Start($Info)
    try {
        $StandardOutput = $Process.StandardOutput.ReadToEnd()
        $StandardError = $Process.StandardError.ReadToEnd()
        $Process.WaitForExit()
        return [pscustomobject][ordered]@{
            ExitCode = [int]$Process.ExitCode
            Output = ($StandardOutput + $StandardError).TrimEnd()
        }
    } finally {
        $Process.Dispose()
    }
}

function Write-ProjProductDevSettingsFixture {
    param(
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$BunVersion,
        [AllowEmptyString()][string]$BunSha256 = ''
    )

    $SetupRoot = Join-Path $DataRoot 'modules\system\dev\setup'
    [void][IO.Directory]::CreateDirectory($SetupRoot)
    [IO.File]::WriteAllText(
        (Join-Path $SetupRoot '_settings.json'),
        (@{
            schema = 'swawkit.proj-dev-settings/v1'
            bun = @{
                mode = 'managed'
                version = $BunVersion
                sha256 = $BunSha256
            }
            pwsh = @{ mode = 'disabled'; version = ''; sha256 = '' }
            msvc = @{ mode = 'disabled'; channel = '' }
            rust = @{
                mode = 'disabled'
                toolchain = ''
                profile = 'minimal'
                host = 'x86_64-pc-windows-msvc'
            }
        } | ConvertTo-Json -Depth 4),
        [Text.UTF8Encoding]::new($false)
    )
}

$ProjRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot '_lib\stage0-toolchain.ps1')
. (Join-Path $PSScriptRoot '_lib\bun-fixture.ps1')

$EnvironmentNames = @(
    'SWAWKIT_PROJ_CORE_COMMAND_PROTOCOL',
    'SWAWKIT_PROJ_CORE_COMMAND_ADDRESS',
    'SWAWKIT_HOME',
    'SWAWKIT_PROJ_TARGET_PROJECT_ROOT',
    'SWAWKIT_PROJ_PROJECT_MODULE_ROOT',
    'SWAWKIT_PROJ_MODULE_ROOTS',
    'SWAWKIT_PROJ_DATA_ROOT',
    'SWAWKIT_PROJ_ENTRY_COMMAND',
    'SWAWKIT_PROJ_CORE_COMMAND_INVOCATION_DIR',
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
$ControlHome = [IO.Path]::GetFullPath((Join-Path $ProjRoot '..\..'))
$EntryName = "test-bun-status-$([Guid]::NewGuid().ToString('N'))"
$PinnedEntryName = "$EntryName-pinned"
$DataRoot = Join-Path $ControlHome "data\proj.$EntryName"
$PinnedDataRoot = Join-Path $ControlHome "data\proj.$PinnedEntryName"
$ReparseDataRoot = Join-Path $ControlHome "data\proj.$EntryName-reparse"
$ModulesJunction = ''
$ResolvedDevPath = [IO.Path]::GetFullPath($DevPath)
if (-not [IO.File]::Exists($ResolvedDevPath)) {
    throw "Toolchain test candidate is missing: $ResolvedDevPath"
}

try {
    $ProjectRoot = Join-Path $TemporaryRoot 'project'
    $ActionRoot = Join-Path $ProjectRoot '.swaw'
    [void][IO.Directory]::CreateDirectory($ActionRoot)
    [void][IO.Directory]::CreateDirectory($DataRoot)
    Set-ProjBunProcessEnvironment -Values @{
        SWAWKIT_PROJ_CORE_COMMAND_PROTOCOL = '3'
        SWAWKIT_PROJ_CORE_COMMAND_ADDRESS = '.dev/status'
        SWAWKIT_HOME = $ControlHome
        SWAWKIT_PROJ_MODULE_ROOTS = (@{
            project = $ActionRoot
        } | ConvertTo-Json -Compress)
        SWAWKIT_PROJ_DATA_ROOT = $DataRoot
        SWAWKIT_PROJ_ENTRY_COMMAND = 'swawkit'
        SWAWKIT_PROJ_CORE_COMMAND_INVOCATION_DIR = $ProjectRoot
        SWAWKIT_PROJ_BUN_MODE = 'managed'
        SWAWKIT_PROJ_BUN_VERSION = '1.2.15'
        SWAWKIT_PROJ_BUN_SHA256 = ''
    }
    $Context = New-ProjStage0TestContext `
        -ProjectRoot $ProjectRoot `
        -DataRoot $DataRoot `
        -CacheDataRoot (Join-Path $ControlHome 'data\proj_cache') `
        -EnvironmentRoot (Join-Path $DataRoot (
            'modules\system\dev\setup\export'
        ))
    Assert-ProjBunTest `
        -Condition ($Context.CacheDataRoot.Equals(
            (Join-Path $ControlHome 'data\proj_cache'),
            [StringComparison]::OrdinalIgnoreCase
        )) `
        -Message 'the Stage-0 fixture did not use the shared cache root'
    Write-ProjProductDevSettingsFixture `
        -DataRoot $DataRoot `
        -BunVersion '1.2.15'
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
    foreach ($RetiredName in @(
        'SWAWKIT_PROJ_BUN_MODE',
        'SWAWKIT_PROJ_BUN_VERSION',
        'SWAWKIT_PROJ_BUN_SHA256'
    )) {
        [Environment]::SetEnvironmentVariable(
            $RetiredName,
            $null,
            [EnvironmentVariableTarget]::Process
        )
    }

    $StatusResult = Invoke-ProjStatusToolchainFixture `
        -Executable $ResolvedDevPath
    Assert-ProjBunTest `
        -Condition (
            $StatusResult.ExitCode -eq 0 -and
            $StatusResult.Output -like '*[[]READY[]]*bun 1.2.15*upstream*' -and
            $StatusResult.Output -like '*GitHub Release digest*' -and
            $StatusResult.Output -like '*.dev/bun/sha256*'
        ) `
        -Message ".dev/status did not report upstream trust: $($StatusResult.Output)"

    $MetadataPath = Get-ProjDevInstallMetadataPath -InstallRoot $InstallRoot
    [byte[]]$OriginalMetadata = [IO.File]::ReadAllBytes($MetadataPath)
    try {
        $InvalidMetadata = [Text.Encoding]::UTF8.GetString(
            $OriginalMetadata
        ) | ConvertFrom-Json
        $InvalidMetadata.sourceUrl = ''
        [IO.File]::WriteAllText(
            $MetadataPath,
            (ConvertTo-ProjDevJsonText -Value $InvalidMetadata),
            [Text.UTF8Encoding]::new($false)
        )
        $MissingSourceUrlStatus = Invoke-ProjStatusToolchainFixture `
            -Executable $ResolvedDevPath
        Assert-ProjBunTest `
            -Condition (
                $MissingSourceUrlStatus.ExitCode -eq 0 -and
                $MissingSourceUrlStatus.Output -cmatch
                    '(?m)^\[MISSING\] bun 1\.2\.15\s+unpinned\s+' -and
                $MissingSourceUrlStatus.Output -cnotmatch
                    '(?m)^\[READY\] bun 1\.2\.15 ' -and
                $MissingSourceUrlStatus.Output -cnotmatch
                    '(?m)^\[MISSING\] bun 1\.2\.15\s+upstream\s+'
            ) `
            -Message (
                '.dev/status trusted metadata without sourceUrl: ' +
                $MissingSourceUrlStatus.Output
            )
    } finally {
        [IO.File]::WriteAllBytes($MetadataPath, $OriginalMetadata)
    }

    $BunxPath = Join-Path $InstallRoot 'bunx.cmd'
    [byte[]]$OriginalBunx = [IO.File]::ReadAllBytes($BunxPath)
    [byte[]]$TamperedBunx = $OriginalBunx.Clone()
    $TamperedBunx[0] = $TamperedBunx[0] -bxor 1
    try {
        [IO.File]::WriteAllBytes($BunxPath, $TamperedBunx)
        $TamperedStatus = Invoke-ProjStatusToolchainFixture `
            -Executable $ResolvedDevPath
        Assert-ProjBunTest `
            -Condition (
                $TamperedStatus.ExitCode -eq 0 -and
                $TamperedStatus.Output -cmatch
                    '(?m)^\[MISSING\] bun 1\.2\.15\s+upstream\s+' -and
                $TamperedStatus.Output -cnotmatch
                    '(?m)^\[READY\] bun 1\.2\.15 '
            ) `
            -Message (
                '.dev/status accepted same-length Bun tampering or lost ' +
                'the validated source trust: ' + $TamperedStatus.Output
            )
    } finally {
        [IO.File]::WriteAllBytes($BunxPath, $OriginalBunx)
    }

    $env:SWAWKIT_PROJ_CORE_COMMAND_ADDRESS = '.dev/setup'
    $SetupResult = Invoke-ProjToolchainCommandFixture `
        -Executable $ResolvedDevPath `
        -Handler '.dev/setup'
    $env:SWAWKIT_PROJ_CORE_COMMAND_ADDRESS = '.dev/status'
    Assert-ProjBunTest `
        -Condition (
            $SetupResult.ExitCode -eq 0 -and
            $SetupResult.Output -like '*Bun 1.2.15 is ready*' -and
            $SetupResult.Output -like '*GitHub Release digest*' -and
            [IO.File]::Exists($Context.EnvCmdPath) -and
            [IO.File]::Exists($Context.EnvPs1Path)
        ) `
        -Message ".dev/setup did not preserve non-blocking trust: $($SetupResult.Output)"
    $ReadyStatus = Invoke-ProjStatusToolchainFixture `
        -Executable $ResolvedDevPath
    Assert-ProjBunTest `
        -Condition ($ReadyStatus.Output -cmatch
            '\[READY\] \.dev/setup publication [a-f0-9]{8}') `
        -Message (
            '.dev/status did not report the provider publication token: ' +
            $ReadyStatus.Output
        )

    [IO.File]::WriteAllText(
        (Get-ProjDevBunSelectionPath -Context $Context),
        (ConvertTo-ProjDevJsonText -Value ([ordered]@{
            schema = 'swawkit.proj-dev.bun-selection.v0'
            selector = 'latest'
            version = '1.2.15'
            sourceSha256 = 'e' * 64
            sourceVerification = 'github'
        })),
        [Text.UTF8Encoding]::new($false)
    )
    Write-ProjProductDevSettingsFixture `
        -DataRoot $DataRoot `
        -BunVersion 'latest'
    $MismatchedSelection = Invoke-ProjStatusToolchainFixture `
        -Executable $ResolvedDevPath
    Assert-ProjBunTest `
        -Condition (
            $MismatchedSelection.ExitCode -eq 0 -and
            $MismatchedSelection.Output -cmatch
                '(?m)^\[MISSING\] bun latest -> 1\.2\.15 ' -and
            $MismatchedSelection.Output -cnotmatch
                '(?m)^\[READY\] bun latest -> 1\.2\.15 '
        ) `
        -Message (
            '.dev/status accepted an install whose digest disagreed with the ' +
            'latest selection: ' + $MismatchedSelection.Output
        )

    $ExternalModules = Join-Path $TemporaryRoot 'external-modules'
    $UnsafeSetupRoot = Join-Path $ExternalModules (
        'system\dev\setup'
    )
    [void][IO.Directory]::CreateDirectory($UnsafeSetupRoot)
    [void][IO.Directory]::CreateDirectory((Join-Path $UnsafeSetupRoot 'export\bun'))
    [IO.File]::WriteAllText(
        (Join-Path $UnsafeSetupRoot 'export\bun\.swawkit-dev-selection.json'),
        (ConvertTo-ProjDevJsonText -Value ([ordered]@{
            schema = 'swawkit.proj-dev.bun-selection.v0'
            selector = 'latest'
            version = '9.9.9'
            sourceSha256 = 'f' * 64
            sourceVerification = 'unverified'
        })),
        [Text.UTF8Encoding]::new($false)
    )
    $ModulesJunction = Join-Path $ReparseDataRoot 'modules'
    [void][IO.Directory]::CreateDirectory($ReparseDataRoot)
    [void](New-Item `
        -ItemType Junction `
        -Path $ModulesJunction `
        -Target $ExternalModules)
    $env:SWAWKIT_PROJ_DATA_ROOT = $ReparseDataRoot
    $UnsafeStatus = Invoke-ProjStatusToolchainFixture `
        -Executable $ResolvedDevPath
    Assert-ProjBunTest `
        -Condition (
            $UnsafeStatus.ExitCode -ne 0 -and
            $UnsafeStatus.Output -like (
                '*Dev Settings directory must be a regular filesystem entry*'
            ) -and
            $UnsafeStatus.Output -notlike '*latest -> 9.9.9*'
        ) `
        -Message (
            '.dev/status followed a reparse-point Export outside DataRoot: ' +
            $UnsafeStatus.Output
        )

    $env:SWAWKIT_PROJ_DATA_ROOT = $PinnedDataRoot
    Write-ProjProductDevSettingsFixture `
        -DataRoot $PinnedDataRoot `
        -BunVersion '1.2.15' `
        -BunSha256 ('e' * 64)
    $PinnedStatus = Invoke-ProjStatusToolchainFixture `
        -Executable $ResolvedDevPath
    Assert-ProjBunTest `
        -Condition (
            $PinnedStatus.ExitCode -eq 0 -and
            $PinnedStatus.Output -like '*[[]MISSING[]]*bun 1.2.15*pinned*' -and
            $PinnedStatus.Output -notlike '*WARNING*' -and
            -not [IO.Directory]::Exists(
                (Join-Path $PinnedDataRoot 'modules\system\dev\setup\export')
            )
        ) `
        -Message ".dev/status was not read-only for pinned state: $($PinnedStatus.Output)"

    Write-Host '[PASS] Proj Bun development status test' `
        -ForegroundColor Green
} finally {
    Exit-ProjBunIsolatedEnvironment -Snapshot $EnvironmentSnapshot
    if (-not [string]::IsNullOrWhiteSpace($ModulesJunction) -and
        [IO.Directory]::Exists($ModulesJunction)) {
        [IO.Directory]::Delete($ModulesJunction)
    }
    foreach ($OwnedDataRoot in @(
        $DataRoot,
        $PinnedDataRoot,
        $ReparseDataRoot
    )) {
        if ([IO.Directory]::Exists($OwnedDataRoot) -and
            [IO.Path]::GetDirectoryName($OwnedDataRoot).Equals(
                (Join-Path $ControlHome 'data'),
                [StringComparison]::OrdinalIgnoreCase
            )) {
            Remove-Item -LiteralPath $OwnedDataRoot -Recurse -Force
        }
    }
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
