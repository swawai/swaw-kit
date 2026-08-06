[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

. (Join-Path $PSScriptRoot '_lib\layout.ps1')
. (Join-Path $PSScriptRoot '_lib\entry.ps1')
$Layout = Get-ProjBootstrapLayout
$Existing = Get-ProjBootstrapLauncherFile `
    -Path $Layout.RootEntryPath `
    -Description 'The root Proj Entry' `
    -AllowMissing
if ($null -ne $Existing) {
    $global:LASTEXITCODE = 0
    return
}

& (Join-Path $PSScriptRoot 'launcher.ps1')
. (Join-Path $PSScriptRoot 'toolchains\runtime.ps1')
$Context = New-ProjBootstrapToolchainContext
$EntryLock = Enter-ProjDevFileLock `
    -Path (Join-Path $Layout.LockRoot 'entry-bootstrap.lock') `
    -ControlledRoot $Context.DataRoot `
    -TimeoutSeconds 1800
try {
    $Existing = Get-ProjBootstrapLauncherFile `
        -Path $Layout.RootEntryPath `
        -Description 'The root Proj Entry' `
        -AllowMissing
    if ($null -eq $Existing) {
        [void](Publish-ProjBootstrapRootEntry `
            -TemplatePath $Layout.LauncherTemplatePath `
            -EntryPath $Layout.RootEntryPath)
    }
} finally {
    $EntryLock.Dispose()
}

$global:LASTEXITCODE = 0
