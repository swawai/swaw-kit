[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'bootstrap-manager-data-root.ps1')
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
& (Join-Path $PSScriptRoot 'dev-setup-interruption.ps1') @CandidateArguments
& (Join-Path $PSScriptRoot 'run-journal-abandonment.ps1') @CandidateArguments
& (Join-Path $PSScriptRoot 'host-release.ps1') @CandidateArguments
& (Join-Path $PSScriptRoot 'development-declaration.ps1')
& (Join-Path $PSScriptRoot 'development-command-layout.ps1')
& (Join-Path $PSScriptRoot 'context-modules.ps1')
& (Join-Path $PSScriptRoot 'module-instantiate.ps1') `
    -ModulePath $CandidateArguments.ModulePath
& (Join-Path $PSScriptRoot 'command-export.ps1')
& (Join-Path $PSScriptRoot 'provider-state.ps1')
& (Join-Path $PSScriptRoot 'provider-activation.ps1')
$TypeScriptTests = @(
    (Join-Path $RepoRoot '.swaw\proj\build\_lib\release-set.test.ts'),
    (Join-Path $RepoRoot '.swaw\proj\build\launcher\_lib\artifact.test.ts'),
    (Join-Path $RepoRoot '.swaw\proj\publish\_lib\runtime-release.test.ts')
)
$ProfilePath = Join-Path $RepoRoot 'data\proj.swawkit\_profile.json'
$Profile = Get-Content -LiteralPath $ProfilePath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$Bun = $Profile.development.bun
$BunExecutable = Join-Path $RepoRoot (
    'data\proj.swawkit\modules\system\dev\setup\export\bun\installs\{0}\bun.exe' -f
    [string]$Bun.version
)
if ($Bun.mode -cne 'managed' -or -not [IO.File]::Exists($BunExecutable)) {
    throw "Proj Module TypeScript tests require the declared managed Bun: '$BunExecutable'."
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
& (Join-Path $PSScriptRoot 'msvc.ps1') `
    -DevPath $CandidateArguments.DevPath
& (Join-Path $PSScriptRoot 'msvc.command.ps1')
& (Join-Path $PSScriptRoot 'msvc.cache.ps1')
& (Join-Path $PSScriptRoot 'rust.ps1')
& (Join-Path $PSScriptRoot 'rust.strict.ps1')

Write-Host '[PASS] Proj test suite' -ForegroundColor Green
$global:LASTEXITCODE = 0
