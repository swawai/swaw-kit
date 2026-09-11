[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'launcher-build.ps1')
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $RepoRoot '_lib\proj\_bootstrap\layout.ps1')
$Layout = Get-ProjBootstrapLayout
$CandidateArguments = @{
    LauncherPath = $Layout.LauncherCandidatePath
    CorePath = Join-Path $Layout.BuildRoot 'release\swawkit-proj.exe'
    HostPath = Join-Path $Layout.BuildRoot 'release\swawkit-proj-host.exe'
    ModulePath = $Layout.ModuleCandidatePath
    DevPath = $Layout.DevCandidatePath
}
& (Join-Path $PSScriptRoot 'launcher-runtime.ps1') @CandidateArguments
& (Join-Path $PSScriptRoot 'launcher-long-path.ps1') `
    -LauncherPath $CandidateArguments.LauncherPath
& (Join-Path $PSScriptRoot 'smoke-entry.ps1') @CandidateArguments
& (Join-Path $PSScriptRoot 'entry-manager.ps1') @CandidateArguments
& (Join-Path $PSScriptRoot 'dev-setup-interruption.ps1') @CandidateArguments
& (Join-Path $PSScriptRoot 'run-journal-abandonment.ps1') @CandidateArguments
& (Join-Path $PSScriptRoot 'host-release.ps1') @CandidateArguments
& (Join-Path $PSScriptRoot 'development-command-layout.ps1')
& (Join-Path $PSScriptRoot 'context-modules.ps1')
& (Join-Path $PSScriptRoot 'module-instantiate.ps1') `
    -ModulePath $CandidateArguments.ModulePath
$TypeScriptTests = @(
    (Join-Path $RepoRoot '.swaw\proj\build\_lib\release-set.test.ts'),
    (Join-Path $RepoRoot '.swaw\proj\build\launcher\_lib\artifact.test.ts'),
    (Join-Path $RepoRoot '.swaw\proj\publish\_lib\runtime-release.test.ts')
)
$BunInstallsRoot = Join-Path $RepoRoot (
    'data\proj.swawkit\modules\system\dev\setup\export\bun\installs'
)
$BunExecutable = @(
    Get-ChildItem -LiteralPath $BunInstallsRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object -Property Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'bun.exe' } |
        Where-Object { [IO.File]::Exists($_) }
)[0]
if ([string]::IsNullOrWhiteSpace([string]$BunExecutable)) {
    throw "Proj Module TypeScript tests require an installed managed Bun below '$BunInstallsRoot'."
}
& $BunExecutable test @TypeScriptTests
if ($LASTEXITCODE -ne 0) {
    throw "Proj Module TypeScript contract tests failed with exit code $LASTEXITCODE."
}
& (Join-Path $PSScriptRoot 'app-build.ps1')
& (Join-Path $PSScriptRoot 'app-publish.ps1')
& (Join-Path $PSScriptRoot 'app-core.ps1')
& (Join-Path $PSScriptRoot 'toolchain.ps1') `
    -DevPath $CandidateArguments.DevPath
& (Join-Path $PSScriptRoot 'toolchain.setup.ps1') `
    -DevPath $CandidateArguments.DevPath
& (Join-Path $PSScriptRoot 'dev-setup-network.ps1') `
    -DevPath $CandidateArguments.DevPath
& (Join-Path $PSScriptRoot 'web.ps1')
& (Join-Path $PSScriptRoot 'bootstrap-contract.ps1')
& (Join-Path $PSScriptRoot 'shell.ps1') @CandidateArguments
& (Join-Path $PSScriptRoot 'install-recovery.ps1')
& (Join-Path $PSScriptRoot 'command-event.ps1')
& (Join-Path $PSScriptRoot 'bun.ps1') `
    -DevPath $CandidateArguments.DevPath
& (Join-Path $PSScriptRoot 'pwsh.ps1')
& (Join-Path $PSScriptRoot 'msvc.ps1')
& (Join-Path $PSScriptRoot 'msvc.cache.ps1')
& (Join-Path $PSScriptRoot 'rust.ps1')

Write-Host '[PASS] Proj test suite' -ForegroundColor Green
$global:LASTEXITCODE = 0
