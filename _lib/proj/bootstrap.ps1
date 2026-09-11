[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

. (Join-Path $PSScriptRoot '_bootstrap\toolchain.ps1')
. (Join-Path $PSScriptRoot '_runtime\release.ps1')
$Layout = Get-ProjBootstrapLayout

function Test-ProjBootstrapRuntime {
    param([Parameter(Mandatory = $true)][object]$BuildLayout)

    $SelectorItem = Get-Item `
        -LiteralPath $BuildLayout.RuntimeCurrentPath `
        -Force `
        -ErrorAction SilentlyContinue
    if ($null -eq $SelectorItem) {
        return $false
    }
    if ($SelectorItem.PSIsContainer -or
        ($SelectorItem.Attributes -band
            [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw (
            'The Bootstrap runtime selector is unsafe: ' +
            $BuildLayout.RuntimeCurrentPath
        )
    }
    try {
        [void](Read-ProjSelectedRuntimeReleaseSet `
            -RuntimeRoot $BuildLayout.RuntimeRoot `
            -ProjHome $BuildLayout.ProjHome)
        return $true
    } catch {
        return $false
    }
}

if (Test-ProjBootstrapRuntime -BuildLayout $Layout) {
    $global:LASTEXITCODE = 0
    return
}

$Context = New-ProjBootstrapToolchainContext
$BootstrapLock = Enter-ProjDevFileLock `
    -Path (Join-Path $Layout.LockRoot 'core-bootstrap.lock') `
    -ControlledRoot $Context.DataRoot `
    -TimeoutSeconds 1800
try {
    if (-not (Test-ProjBootstrapRuntime -BuildLayout $Layout)) {
        Invoke-ProjBootstrapToolchain -Action {
            param($Toolchain, $BuildLayout)

            $TargetDirectory = Assert-ProjDevPathInsideDataRoot `
                -Path $BuildLayout.BuildRoot `
                -DataRoot $Toolchain.Context.DataRoot `
                -Activity 'building the Bootstrap application'
            $BuildLock = Enter-ProjDevFileLock `
                -Path (Join-Path $BuildLayout.LockRoot 'app-build.lock') `
                -ControlledRoot $Toolchain.Context.DataRoot `
                -TimeoutSeconds 1800
            try {
                & $BuildLayout.AppBuildPath `
                    -CargoPath ([string]$Toolchain.CargoPath) `
                    -TargetDirectory $TargetDirectory | Out-Host
            } finally {
                $BuildLock.Dispose()
            }
            $ModuleTargetDirectory = Assert-ProjDevPathInsideDataRoot `
                -Path $BuildLayout.ModuleBuildRoot `
                -DataRoot $Toolchain.Context.DataRoot `
                -Activity 'building the Bootstrap Module executable'
            $ModuleBuildLock = Enter-ProjDevFileLock `
                -Path (Join-Path $BuildLayout.LockRoot 'module-build.lock') `
                -ControlledRoot $Toolchain.Context.DataRoot `
                -TimeoutSeconds 1800
            try {
                Invoke-ProjBootstrapRustProductBuild `
                    -ProductName 'Module' `
                    -CandidateName 'swawkit-proj-module.exe' `
                    -CargoPath ([string]$Toolchain.CargoPath) `
                    -ManifestPath $BuildLayout.ModuleManifestPath `
                    -TargetDirectory $ModuleTargetDirectory | Out-Host
            } finally {
                $ModuleBuildLock.Dispose()
            }
            $DevTargetDirectory = Assert-ProjDevPathInsideDataRoot `
                -Path $BuildLayout.DevBuildRoot `
                -DataRoot $Toolchain.Context.DataRoot `
                -Activity 'building the Bootstrap Dev runtime'
            $DevBuildLock = Enter-ProjDevFileLock `
                -Path (Join-Path $BuildLayout.LockRoot 'dev-build.lock') `
                -ControlledRoot $Toolchain.Context.DataRoot `
                -TimeoutSeconds 1800
            try {
                Invoke-ProjBootstrapRustProductBuild `
                    -ProductName 'Dev' `
                    -CandidateName 'swawkit-proj-dev.exe' `
                    -CargoPath ([string]$Toolchain.CargoPath) `
                    -ManifestPath $BuildLayout.DevManifestPath `
                    -TargetDirectory $DevTargetDirectory | Out-Host
            } finally {
                $DevBuildLock.Dispose()
            }
            & $BuildLayout.RuntimePublishPath `
                -CandidateCorePath (Join-Path $TargetDirectory (
                    'release\swawkit-proj.exe'
                )) `
                -CandidateHostPath (Join-Path $TargetDirectory (
                    'release\swawkit-proj-host.exe'
                )) `
                -CandidateModulePath $BuildLayout.ModuleCandidatePath `
                -CandidateDevPath $BuildLayout.DevCandidatePath `
                -CommandRuntimeId ([string]$Toolchain.CommandRuntimeId) `
                -RuntimeRoot $BuildLayout.RuntimeRoot `
                -ProjHome $BuildLayout.ProjHome `
                -CandidateRoot $Toolchain.Context.DataRoot
        }
    }
} finally {
    $BootstrapLock.Dispose()
}

$global:LASTEXITCODE = 0
