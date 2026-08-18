[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ProjRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $ProjRoot '_toolchain\bootstrap.ps1')

$Toolchain = Initialize-ProjBootstrapToolchain
$ContextRoot = Join-Path $ProjRoot 'system\context'
$Manifest = Join-Path $ContextRoot 'Cargo.toml'

& $Toolchain.CargoPath fmt --manifest-path $Manifest -- --check
if ($LASTEXITCODE -ne 0) {
    throw "Context module formatting failed: $Manifest"
}

$TargetRoot = Assert-ProjDevPathInsideDataRoot `
    -Path (Join-Path $Toolchain.Context.DataRoot 'build\context-module-test') `
    -DataRoot $Toolchain.Context.DataRoot `
    -Activity 'testing Context domain modules'
$TestLock = Enter-ProjDevFileLock `
    -Path (Join-Path $Toolchain.Context.LockRoot 'context-module-test.lock') `
    -ControlledRoot $Toolchain.Context.DataRoot `
    -TimeoutSeconds 1800
try {
    & $Toolchain.CargoPath `
        test `
        --locked `
        --offline `
        --manifest-path $Manifest `
        --target-dir $TargetRoot
    if ($LASTEXITCODE -ne 0) {
        throw 'Context domain engine tests failed.'
    }
} finally {
    $TestLock.Dispose()
}

Write-Host '[PASS] Proj Context domain module suite' -ForegroundColor Green
$global:LASTEXITCODE = 0
