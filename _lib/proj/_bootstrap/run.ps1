[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

. (Join-Path $PSScriptRoot '_lib\layout.ps1')
$Layout = Get-ProjBootstrapLayout
if ([IO.File]::Exists($Layout.RuntimePath)) {
    $global:LASTEXITCODE = 0
    return
}

. (Join-Path $PSScriptRoot 'toolchains\runtime.ps1')
$Context = New-ProjBootstrapToolchainContext
$BootstrapLock = Enter-ProjDevFileLock `
    -Path (Join-Path $Layout.LockRoot 'core-bootstrap.lock') `
    -ControlledRoot $Context.DataRoot `
    -TimeoutSeconds 1800
try {
    if (-not [IO.File]::Exists($Layout.RuntimePath)) {
        & (Join-Path $PSScriptRoot 'build.ps1')
        & (Join-Path $PSScriptRoot 'publish.ps1')
    }
} finally {
    $BootstrapLock.Dispose()
}

$global:LASTEXITCODE = 0
