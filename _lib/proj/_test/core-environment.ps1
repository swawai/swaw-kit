[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ProjRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $ProjRoot '_core\engine.ps1')

function Assert-ProjCoreEnvironmentTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function ConvertTo-ProjCoreEnvironmentLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)
    return "'$($Value.Replace("'", "''"))'"
}

$TestTemporaryBase = [IO.Path]::GetFullPath(
    (Join-Path $ProjRoot '..\..\data\_test')
)
[void][IO.Directory]::CreateDirectory($TestTemporaryBase)
$TemporaryRoot = Join-Path $TestTemporaryBase (
    "swawkit-proj-core-environment-$([Guid]::NewGuid().ToString('N'))"
)
$ProjectRoot = Join-Path $TemporaryRoot 'project'
$ActionRoot = Join-Path $ProjectRoot '.swaw'
$CommandRoot = Join-Path $ActionRoot 'probe'
$DataRoot = Join-Path $ProjectRoot 'data\proj.fixture'
$EnvironmentRoot = Join-Path $DataRoot 'dev_env'
$EntryPath = Join-Path $ProjectRoot 'fixture.cmd'
$CapturePath = Join-Path $TemporaryRoot 'capture.txt'

$OwnedVariables = @(
    'SWAWKIT_PROJ_PROTOCOL',
    'SWAWKIT_PROJ_ID',
    'SWAWKIT_PROJ_DIR',
    'SWAWKIT_PROJ_ACTION_ROOT',
    'SWAWKIT_PROJ_DATA_ROOT',
    'SWAWKIT_PROJ_ENTRY_COMMAND',
    'SWAWKIT_PROJ_ENTRY_FILE',
    'SWAWKIT_TEST_CORE_ENV_CAPTURE',
    'SWAWKIT_TEST_CORE_ENV_MARKER',
    'SWAWKIT_TEST_CORE_ENV_LOAD_COUNT'
)
$SavedEnvironment = @{}
foreach ($Name in $OwnedVariables) {
    $SavedEnvironment[$Name] = [Environment]::GetEnvironmentVariable(
        $Name,
        [EnvironmentVariableTarget]::Process
    )
}
$SavedDevelopmentEnvironment = @{}
$ProcessEnvironment = [Environment]::GetEnvironmentVariables(
    [EnvironmentVariableTarget]::Process
)
foreach ($Name in [string[]]@($ProcessEnvironment.Keys)) {
    if ($Name.StartsWith(
        'SWAWKIT_DEV_',
        [StringComparison]::OrdinalIgnoreCase
    )) {
        $SavedDevelopmentEnvironment[$Name] = [string]$ProcessEnvironment[$Name]
        [Environment]::SetEnvironmentVariable($Name, $null, 'Process')
    }
}

try {
    [void][IO.Directory]::CreateDirectory($CommandRoot)
    [IO.File]::WriteAllText($EntryPath, '@exit /b 0')
    [Environment]::SetEnvironmentVariable(
        'SWAWKIT_PROJ_DATA_ROOT',
        $null,
        [EnvironmentVariableTarget]::Process
    )
    [void](Resolve-ProjProjectDataRoot `
        -ProjectRoot $ProjectRoot `
        -ActionRoot $ActionRoot `
        -EntryFile $EntryPath)
    [void][IO.Directory]::CreateDirectory($EnvironmentRoot)
    [IO.File]::WriteAllText(
        (Join-Path $CommandRoot 'run.ps1'),
        @'
$ErrorActionPreference = 'Stop'
[IO.File]::WriteAllText(
    $env:SWAWKIT_TEST_CORE_ENV_CAPTURE,
    [string]$env:SWAWKIT_TEST_CORE_ENV_MARKER
)
$global:LASTEXITCODE = 0
'@
    )

    $env:SWAWKIT_PROJ_PROTOCOL = '1'
    $env:SWAWKIT_PROJ_ID = 'core-environment-fixture'
    $env:SWAWKIT_PROJ_DIR = $ProjectRoot
    $env:SWAWKIT_PROJ_ACTION_ROOT = $ActionRoot
    $env:SWAWKIT_PROJ_DATA_ROOT = $DataRoot
    $env:SWAWKIT_PROJ_ENTRY_COMMAND = 'fixture'
    $env:SWAWKIT_PROJ_ENTRY_FILE = $EntryPath
    $env:SWAWKIT_TEST_CORE_ENV_CAPTURE = $CapturePath
    $env:SWAWKIT_TEST_CORE_ENV_MARKER = 'ambient'

    $NestedDirectory = Join-Path $ProjectRoot 'nested'
    $NestedEntry = Join-Path $NestedDirectory 'fixture.cmd'
    [void][IO.Directory]::CreateDirectory($NestedDirectory)
    [IO.File]::WriteAllText($NestedEntry, '@exit /b 0')
    $env:SWAWKIT_PROJ_ENTRY_FILE = $NestedEntry
    $RejectedNestedEntry = $false
    try {
        [void](Get-ProjProjectContext)
    } catch {
        $RejectedNestedEntry = $_.Exception.Message -like (
            '*entry file must be located directly*'
        )
    }
    Assert-ProjCoreEnvironmentTest `
        -Condition $RejectedNestedEntry `
        -Message 'an entry below the project root was accepted'
    $env:SWAWKIT_PROJ_ENTRY_FILE = $EntryPath

    $ExitCode = Invoke-ProjMain -KernelRoot $ProjRoot -Arguments @('probe')
    Assert-ProjCoreEnvironmentTest `
        -Condition ($ExitCode -eq 0 -and
            [IO.File]::ReadAllText($CapturePath) -ceq 'ambient') `
        -Message 'a project without a managed environment lost the ambient PATH contract'

    $GenerationId = '0123456789abcdef'
    [IO.File]::WriteAllText(
        (Join-Path $EnvironmentRoot 'env.cmd'),
        "@echo off`r`nset `"SWAWKIT_DEV_GENERATION_ID=$GenerationId`"`r`n"
    )
    $Ps1 = @(
        "`$env:SWAWKIT_DEV_GENERATION_ID = '$GenerationId'"
        "`$env:SWAWKIT_DEV_ENV_SCHEMA = 'swawkit.proj-dev.environment.v0'"
        "`$env:SWAWKIT_DEV_PROJECT_ID = 'core-environment-fixture'"
        (
            "`$env:SWAWKIT_DEV_PROJECT_ROOT = " +
            (ConvertTo-ProjCoreEnvironmentLiteral -Value $ProjectRoot)
        )
        (
            "`$env:SWAWKIT_DEV_ENV_ROOT = " +
            (ConvertTo-ProjCoreEnvironmentLiteral -Value $EnvironmentRoot)
        )
        '$env:SWAWKIT_TEST_CORE_ENV_MARKER = ''managed'''
        (
            '$env:SWAWKIT_TEST_CORE_ENV_LOAD_COUNT = ' +
            '([int]$env:SWAWKIT_TEST_CORE_ENV_LOAD_COUNT + 1).ToString()'
        )
    ) -join "`r`n"
    [IO.File]::WriteAllText(
        (Join-Path $EnvironmentRoot 'env.ps1'),
        "$Ps1`r`n"
    )

    foreach ($Iteration in 1..2) {
        $ExitCode = Invoke-ProjMain -KernelRoot $ProjRoot -Arguments @('probe')
        Assert-ProjCoreEnvironmentTest `
            -Condition ($ExitCode -eq 0 -and
                [IO.File]::ReadAllText($CapturePath) -ceq 'managed') `
            -Message 'the Core did not activate the published environment before the Action'
    }
    Assert-ProjCoreEnvironmentTest `
        -Condition ([string]$env:SWAWKIT_TEST_CORE_ENV_LOAD_COUNT -ceq '1') `
        -Message 'the Core imported the same environment generation more than once'

    $env:SWAWKIT_DEV_PROJECT_ID = 'foreign-project'
    $env:SWAWKIT_DEV_PROJECT_ROOT = Join-Path $TemporaryRoot 'foreign-project'
    $env:SWAWKIT_DEV_ENV_ROOT = Join-Path $TemporaryRoot (
        'foreign-project\data\dev_env'
    )
    foreach ($Address in @('probe')) {
        $RejectedForeignEnvironment = $false
        try {
            $ForeignExitCode = Invoke-ProjMain `
                -KernelRoot $ProjRoot `
                -Arguments @($Address)
            $RejectedForeignEnvironment = $ForeignExitCode -eq 1
        } catch {
            $RejectedForeignEnvironment =
                $_.Exception.Message -like (
                    "*Another project's development environment*"
                )
        }
        Assert-ProjCoreEnvironmentTest `
            -Condition $RejectedForeignEnvironment `
            -Message (
                "the Core did not reject a foreign environment before $Address"
            )
    }
} finally {
    if ([IO.Directory]::Exists($TemporaryRoot)) {
        [IO.Directory]::Delete($TemporaryRoot, $true)
    }
    $CurrentEnvironment = [Environment]::GetEnvironmentVariables(
        [EnvironmentVariableTarget]::Process
    )
    foreach ($Name in [string[]]@($CurrentEnvironment.Keys)) {
        if ($Name.StartsWith(
            'SWAWKIT_DEV_',
            [StringComparison]::OrdinalIgnoreCase
        )) {
            [Environment]::SetEnvironmentVariable($Name, $null, 'Process')
        }
    }
    foreach ($Name in $SavedDevelopmentEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable(
            $Name,
            [string]$SavedDevelopmentEnvironment[$Name],
            'Process'
        )
    }
    foreach ($Name in $OwnedVariables) {
        [Environment]::SetEnvironmentVariable(
            $Name,
            $SavedEnvironment[$Name],
            'Process'
        )
    }
}

Write-Host '[PASS] Proj Core development environment activation' `
    -ForegroundColor Green
$global:LASTEXITCODE = 0
