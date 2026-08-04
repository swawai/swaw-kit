[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

. (Join-Path $PSScriptRoot 'toolchains\runtime.ps1')

$Toolchain = Initialize-ProjBootstrapToolchain
$Layout = Get-ProjBootstrapLayout
$TargetDirectory = Assert-ProjDevPathInsideDataRoot `
    -Path $Layout.BuildRoot `
    -DataRoot $Toolchain.Context.DataRoot `
    -Activity 'building the Bootstrap application'
$BuildLock = Enter-ProjDevFileLock `
    -Path (Join-Path $Layout.LockRoot 'app-build.lock') `
    -ControlledRoot $Toolchain.Context.DataRoot `
    -TimeoutSeconds 1800
try {
    & $Layout.AppBuildPath `
        -CargoPath ([string]$Toolchain.CargoPath) `
        -TargetDirectory $TargetDirectory
} finally {
    $BuildLock.Dispose()
}
