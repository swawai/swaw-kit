[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Assert-ProjLauncherPolicyTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$PolicyPath = Join-Path $RepoRoot (
    '.swaw\proj\build\launcher\_lib\policy.ps1'
)
$TestBase = Join-Path $RepoRoot 'data\_test'
$TemporaryRoot = Join-Path $TestBase (
    "swawkit-proj-launcher-policy-$([Guid]::NewGuid().ToString('N'))"
)
$AmbientBin = Join-Path $TemporaryRoot 'ambient-bin'
$ManagedHome = Join-Path $TemporaryRoot 'managed-msvc'

$OwnedVariables = @(
    'SWAWKIT_PROJ_TARGET_PROJECT_ROOT',
    'SWAWKIT_PROJ_ENTRY_COMMAND'
)
$SavedEnvironment = @{}
foreach ($Name in $OwnedVariables) {
    $SavedEnvironment[$Name] = [Environment]::GetEnvironmentVariable(
        $Name,
        [EnvironmentVariableTarget]::Process
    )
}
$SavedPath = [string]$env:PATH
$SavedDevelopmentEnvironment = @{}
$ProcessEnvironment = [Environment]::GetEnvironmentVariables(
    [EnvironmentVariableTarget]::Process
)
foreach ($Name in [string[]]@($ProcessEnvironment.Keys)) {
    if ($Name.StartsWith(
        'SWAWKIT_PROJ_DEV_',
        [StringComparison]::OrdinalIgnoreCase
    )) {
        $SavedDevelopmentEnvironment[$Name] = [string]$ProcessEnvironment[$Name]
        [Environment]::SetEnvironmentVariable($Name, $null, 'Process')
    }
}

try {
    . $PolicyPath
    [void][IO.Directory]::CreateDirectory($AmbientBin)
    [void][IO.Directory]::CreateDirectory($ManagedHome)
    foreach ($Name in @('cl.exe', 'link.exe')) {
        [IO.File]::Copy(
            $env:ComSpec,
            (Join-Path $AmbientBin $Name),
            $true
        )
    }
    $env:PATH = "$AmbientBin$([IO.Path]::PathSeparator)$SavedPath"
    $env:SWAWKIT_PROJ_TARGET_PROJECT_ROOT = $RepoRoot
    $env:SWAWKIT_PROJ_ENTRY_COMMAND = 'fixture'

    $AmbientCompiler = Get-Command cl.exe `
        -CommandType Application |
        Select-Object -First 1
    Assert-ProjLauncherPolicyTest `
        -Condition ([IO.Path]::GetFullPath($AmbientCompiler.Source).Equals(
            (Join-Path $AmbientBin 'cl.exe'),
            [StringComparison]::OrdinalIgnoreCase
        )) `
        -Message 'the fixture did not expose an ambient system-like compiler'

    $RejectedAmbientFallback = $false
    try {
        [void](Resolve-ManagedMsvcExecutable -Name 'cl.exe')
    } catch {
        $RejectedAmbientFallback =
            $_.Exception.Message -like '*requires the project-managed MSVC*'
    }
    Assert-ProjLauncherPolicyTest `
        -Condition $RejectedAmbientFallback `
        -Message 'launcher silently accepted ambient cl.exe without managed MSVC'

    $env:SWAWKIT_PROJ_DEV_ENV_SCHEMA = 'swawkit.proj-dev.environment.v0'
    $env:SWAWKIT_PROJ_DEV_MSVC_MODE = 'managed'
    $env:SWAWKIT_PROJ_DEV_MSVC_HOME = $ManagedHome
    $env:SWAWKIT_PROJ_DEV_MSVC_SIGNATURE = 'fixture-signature'
    $RejectedOutsideTool = $false
    try {
        [void](Resolve-ManagedMsvcExecutable -Name 'cl.exe')
    } catch {
        $RejectedOutsideTool =
            $_.Exception.Message -like '*resolved outside*managed MSVC*'
    }
    Assert-ProjLauncherPolicyTest `
        -Condition $RejectedOutsideTool `
        -Message 'launcher trusted a compiler outside the declared managed root'
} finally {
    $env:PATH = $SavedPath
    if ([IO.Directory]::Exists($TemporaryRoot)) {
        [IO.Directory]::Delete($TemporaryRoot, $true)
    }
    $CurrentEnvironment = [Environment]::GetEnvironmentVariables(
        [EnvironmentVariableTarget]::Process
    )
    foreach ($Name in [string[]]@($CurrentEnvironment.Keys)) {
        if ($Name.StartsWith(
            'SWAWKIT_PROJ_DEV_',
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

Write-Host '[PASS] Proj launcher managed-tool policy' -ForegroundColor Green
$global:LASTEXITCODE = 0
