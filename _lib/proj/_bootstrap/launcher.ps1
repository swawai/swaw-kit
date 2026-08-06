[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

. (Join-Path $PSScriptRoot '_lib\layout.ps1')
. (Join-Path $PSScriptRoot '_lib\entry.ps1')
$Layout = Get-ProjBootstrapLayout
$Existing = Get-ProjBootstrapLauncherFile `
    -Path $Layout.LauncherTemplatePath `
    -Description 'The Proj Launcher template' `
    -AllowMissing
if ($null -ne $Existing) {
    $global:LASTEXITCODE = 0
    return
}

# Toolchain initialization intentionally rewrites PATH and SWAWKIT_PROJ_DEV_*.
# A preparation call may run inside a larger test or developer shell, so keep
# that product-build environment inside this action.
Invoke-ProjBootstrapEnvironmentIsolated -Action {
    # The Launcher's runtime test needs a real Core. The Core Bootstrap also
    # makes the fixed toolchain available without trusting ambient PATH.
    Initialize-ProjBootstrapCore `
        -RuntimePath $Layout.RuntimePath `
        -BootstrapPath (Join-Path $PSScriptRoot 'run.ps1')
    . (Join-Path $PSScriptRoot 'toolchains\runtime.ps1')
    $Context = New-ProjBootstrapToolchainContext
    $LauncherLock = Enter-ProjDevFileLock `
        -Path (Join-Path $Layout.LockRoot 'launcher-bootstrap.lock') `
        -ControlledRoot $Context.DataRoot `
        -TimeoutSeconds 1800
    try {
        $Existing = Get-ProjBootstrapLauncherFile `
            -Path $Layout.LauncherTemplatePath `
            -Description 'The Proj Launcher template' `
            -AllowMissing
        if ($null -eq $Existing) {
            [void](Assert-ProjBootstrapPhysicalDirectory `
                -Path (Split-Path `
                    -Path $Layout.LauncherTemplatePath `
                    -Parent) `
                -Description 'The Launcher template directory')
            [void](Initialize-ProjBootstrapToolchain)
            $env:SWAWKIT_HOME = $Layout.ProjHome
            $env:SWAWKIT_PROJ_TARGET_PROJECT_ROOT = $Layout.ProjHome
            $env:SWAWKIT_PROJ_DATA_ROOT = $Context.DataRoot
            $CompilerPath = Resolve-ProjBootstrapMsvcExecutable -Name 'cl.exe'
            $LinkerPath = Resolve-ProjBootstrapMsvcExecutable -Name 'link.exe'
            & $Layout.LauncherBuildPath `
                -CompilerPath $CompilerPath `
                -LinkerPath $LinkerPath `
                -OutputPath $Layout.LauncherTemplatePath
            [void](Get-ProjBootstrapLauncherFile `
                -Path $Layout.LauncherTemplatePath `
                -Description 'The built Proj Launcher template')
        }
    } finally {
        $LauncherLock.Dispose()
    }
}

$global:LASTEXITCODE = 0
