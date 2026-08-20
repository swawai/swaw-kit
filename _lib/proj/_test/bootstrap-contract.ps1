[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Assert-ProjBootstrapContractTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$ProjRoot = Join-Path $RepoRoot '_lib\proj'
. (Join-Path $ProjRoot '_bootstrap\layout.ps1')

$Layout = Get-ProjBootstrapLayout
$Contract = Read-ProjBootstrapContract
Assert-ProjBootstrapContractTest `
    -Condition (
        [string]$Contract.Schema -ceq 'swawkit.proj-bootstrap/v2' -and
        [string]$Contract.RustToolchain -cmatch '^\d+\.\d+\.\d+$' -and
        [string]$Contract.MsvcChannel -cmatch '^\d+$' -and
        [string]$Contract.BunVersion -cmatch '^\d+\.\d+\.\d+$' -and
        [string]$Contract.BunSha256 -cmatch '^[a-f0-9]{64}$' -and
        [string]$Contract.PwshVersion -cmatch '^\d+\.\d+\.\d+$' -and
        [string]$Contract.PwshSha256 -cmatch '^[a-f0-9]{64}$'
    ) `
    -Message 'the Bootstrap contract does not pin a valid product toolchain'
Assert-ProjBootstrapContractTest `
    -Condition (
        [IO.Path]::GetFullPath($Layout.BootstrapDataRoot).Equals(
            (Join-Path $RepoRoot 'data\proj_cache\bootstrap'),
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        [IO.Path]::GetFullPath($Layout.BuildRoot).Equals(
            (Join-Path $RepoRoot 'data\proj_cache\bootstrap\build\app'),
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        [IO.Path]::GetFullPath($Layout.ModuleBuildRoot).Equals(
            (Join-Path $RepoRoot 'data\proj_cache\bootstrap\build\module'),
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        [IO.Path]::GetFullPath($Layout.ModuleManifestPath).Equals(
            (Join-Path $RepoRoot '_lib\proj\system\module\Cargo.toml'),
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        [IO.Path]::GetFullPath($Layout.ModuleCandidatePath).Equals(
            (Join-Path $RepoRoot (
                'data\proj_cache\bootstrap\build\module\release\' +
                'swawkit-proj-module.exe'
            )),
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        [IO.Path]::GetFullPath($Layout.ManagerDataRoot).Equals(
            (Join-Path $RepoRoot 'data\proj.swawkit'),
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        [IO.Path]::GetFullPath($Layout.ManagerEntryIdPath).Equals(
            (Join-Path $RepoRoot 'data\proj.swawkit\entry.id'),
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        [IO.Path]::GetFullPath($Layout.RuntimeRoot).Equals(
            (Join-Path $RepoRoot 'data\proj.swawkit\runtime'),
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        [IO.Path]::GetFullPath($Layout.RuntimeCurrentPath).Equals(
            (Join-Path $RepoRoot 'data\proj.swawkit\runtime\current'),
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        [IO.Path]::GetFullPath($Layout.LauncherBuildRoot).Equals(
            (Join-Path $RepoRoot 'data\proj_cache\bootstrap\build\launcher'),
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        [IO.Path]::GetFullPath($Layout.LauncherCandidatePath).Equals(
            (Join-Path $RepoRoot (
                'data\proj_cache\bootstrap\build\launcher\release\' +
                'swawkit.exe'
            )),
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        [IO.Path]::GetFullPath($Layout.LauncherBuildPath).Equals(
            (Join-Path $RepoRoot '_lib\proj\_launcher\build.ps1'),
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        [IO.Path]::GetFullPath($Layout.RuntimePublishPath).Equals(
            (Join-Path $RepoRoot '_lib\proj\_runtime\publish.ps1'),
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        [IO.Path]::GetFullPath($Layout.ContractPath).Equals(
            (Join-Path $RepoRoot '_lib\proj\bootstrap.json'),
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        [IO.Path]::GetFullPath($Layout.BootstrapEntryPath).Equals(
            (Join-Path $RepoRoot '_lib\proj\bootstrap.ps1'),
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        [IO.Path]::GetFullPath($Layout.BootstrapSetupPath).Equals(
            (Join-Path $RepoRoot '_lib\proj\_bootstrap\setup.ps1'),
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        [IO.Path]::GetFullPath($Layout.EnvironmentPath).Equals(
            (Join-Path $RepoRoot 'data\proj_cache\bootstrap\environment.json'),
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        [IO.Path]::GetFullPath($Layout.CommandRuntimeRoot).Equals(
            (Join-Path $RepoRoot 'data\proj_cache\bootstrap\command-runtimes'),
            [StringComparison]::OrdinalIgnoreCase
        )
    ) `
    -Message 'the Bootstrap layout does not separate manager state and shared cache'

$AppBuild = [IO.File]::ReadAllText(
    (Join-Path $RepoRoot '_lib\proj\_app\build.ps1')
)
Assert-ProjBootstrapContractTest `
    -Condition (
        -not $AppBuild.Contains('_bin') -and
        -not $AppBuild.Contains('[IO.File]::Replace')
    ) `
    -Message 'the App build primitive still owns runtime publication'

$LauncherBuild = [IO.File]::ReadAllText($Layout.LauncherBuildPath)
Assert-ProjBootstrapContractTest `
    -Condition (
        -not $LauncherBuild.Contains('_toolchain') -and
        -not $LauncherBuild.Contains('bootstrap.ps1') -and
        -not $LauncherBuild.Contains('launcher-runtime.ps1') -and
        $LauncherBuild.Contains('build.json') -and
        -not $LauncherBuild.Contains('/ENTRY:launcher_entry')
    ) `
    -Message 'the Launcher build primitive still owns orchestration'

$BootstrapEntry = [IO.File]::ReadAllText($Layout.BootstrapEntryPath)
Assert-ProjBootstrapContractTest `
    -Condition (
        -not $BootstrapEntry.Contains('LauncherBuild') -and
        $BootstrapEntry.Contains('Invoke-ProjBootstrapRustProductBuild') -and
        $BootstrapEntry.Contains('CandidateModulePath') -and
        $BootstrapEntry.Contains('CandidateDevPath') -and
        $BootstrapEntry.Contains('MigrateLegacyManagerDataRoot') -and
        $BootstrapEntry.Contains('Initialize-ProjManagerDataRoot')
    ) `
    -Message 'the cold Bootstrap entry still builds the Launcher'

$BootstrapToolchain = [IO.File]::ReadAllText(
    (Join-Path $ProjRoot '_bootstrap\toolchain.ps1')
)
Assert-ProjBootstrapContractTest `
    -Condition (
        -not $BootstrapToolchain.Contains('.dev\setup') -and
        -not $BootstrapToolchain.Contains('system\dev') -and
        -not $BootstrapToolchain.Contains(
            'SWAWKIT_PROJ_MODULE_KERNEL_DEV_SETUP_'
        ) -and
        $BootstrapToolchain.Contains(
            'SWAWKIT_PROJ_TOOLCHAIN_BOOTSTRAP_ENVIRONMENT_REVISION'
        ) -and
        $BootstrapToolchain.Contains('Publish-ProjBootstrapEnvironment') -and
        $BootstrapToolchain.Contains('Publish-ProjBootstrapCommandRuntime') -and
        -not $BootstrapToolchain.Contains(
            'Set-ProjBootstrapToolchainDeclarations'
        )
    ) `
    -Message 'the Bootstrap toolchain still depends on development setup'

$PrivateLayoutChecks = @(
    [IO.File]::Exists((Join-Path $ProjRoot '_bootstrap\layout.ps1'))
    [IO.File]::Exists((Join-Path $ProjRoot '_bootstrap\toolchain.ps1'))
    [IO.File]::Exists((Join-Path $ProjRoot '_bootstrap\environment.ps1'))
    [IO.File]::Exists((Join-Path $ProjRoot '_bootstrap\setup.ps1'))
    [IO.File]::Exists((Join-Path $ProjRoot '_runtime\release.ps1'))
    [IO.File]::Exists((Join-Path $ProjRoot '_runtime\publish.ps1'))
    [IO.File]::Exists((Join-Path $ProjRoot (
        '_runtime\manager-data-root.ps1'
    )))
    [IO.File]::Exists((Join-Path $ProjRoot 'system\dev\_lib\process.ps1'))
    (-not [IO.File]::Exists((Join-Path $ProjRoot (
        'system\dev\_lib\runtime.ps1'
    ))))
    (-not [IO.File]::Exists((Join-Path $ProjRoot (
        'system\dev\_lib\setup.ps1'
    ))))
    [IO.File]::Exists((Join-Path $ProjRoot 'system\dev\Cargo.toml'))
    [IO.File]::Exists((Join-Path $ProjRoot 'system\dev\src\main.rs'))
    (-not [IO.File]::Exists((Join-Path $ProjRoot (
        '_toolchain\bootstrap.ps1'
    ))))
    (-not [IO.File]::Exists((Join-Path $ProjRoot (
        '_toolchain\runtime.ps1'
    ))))
    (-not [IO.File]::Exists((Join-Path $ProjRoot (
        '_toolchain\setup.ps1'
    ))))
    (-not [IO.File]::Exists((Join-Path $ProjRoot (
        '_toolchain\_lib\runtime-release.ps1'
    ))))
    (-not [IO.File]::Exists((Join-Path $ProjRoot '_app\publish.ps1')))
)
Assert-ProjBootstrapContractTest `
    -Condition ($PrivateLayoutChecks -notcontains $false) `
    -Message 'Bootstrap, Runtime publication, and development ownership are mixed'

$BootstrapSetup = [IO.File]::ReadAllText($Layout.BootstrapSetupPath)
Assert-ProjBootstrapContractTest `
    -Condition (
        $BootstrapSetup.Contains('Invoke-ProjBootstrapToolchain') -and
        -not $BootstrapSetup.Contains('Invoke-ProjBootstrapAppBuild') -and
        -not $BootstrapSetup.Contains('Publish-ProjRuntimeReleaseSet') -and
        -not $BootstrapSetup.Contains('.dev/setup')
    ) `
    -Message 'the Bootstrap environment repair path owns product build or publication'

$BootstrapEnvironment = [IO.File]::ReadAllText(
    (Join-Path $ProjRoot '_bootstrap\environment.ps1')
)
Assert-ProjBootstrapContractTest `
    -Condition (
        $BootstrapEnvironment.Contains(
            'swawkit.proj-bootstrap-environment/v1'
        ) -and
        $BootstrapEnvironment.Contains('ContractPath') -and
        $BootstrapEnvironment.Contains('contractRevision')
    ) `
    -Message 'the Bootstrap Native builder projection has no explicit contract'

Assert-ProjBootstrapContractTest `
    -Condition (-not [IO.Directory]::Exists((Join-Path $RepoRoot (
        '.swaw\proj\build\app\bootstrap'
    )))) `
    -Message 'the internal Bootstrap build is still exposed as a project Module command'

Write-Host '[PASS] Proj Bootstrap contract' -ForegroundColor Green
$global:LASTEXITCODE = 0
