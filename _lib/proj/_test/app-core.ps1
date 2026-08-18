[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ProjRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $ProjRoot '_toolchain\bootstrap.ps1')

$Toolchain = Initialize-ProjBootstrapToolchain
$RustProjects = @(
    @{
        Name = 'shared protocol'
        ManifestPath = Join-Path $ProjRoot '_protocol\Cargo.toml'
        TargetName = 'protocol-test'
    },
    @{
        Name = 'Module manager'
        ManifestPath = Join-Path $ProjRoot 'system\module\_app\Cargo.toml'
        TargetName = 'module-test'
    },
    @{
        Name = 'Core'
        ManifestPath = Join-Path $ProjRoot '_app\Cargo.toml'
        TargetName = 'app-test'
    }
)

foreach ($Project in $RustProjects) {
    & $Toolchain.CargoPath `
        fmt `
        --manifest-path $Project.ManifestPath `
        -- `
        --check
    if ($LASTEXITCODE -ne 0) {
        throw "Rust $($Project.Name) formatting check failed with exit code $LASTEXITCODE."
    }
}

$TestLock = Enter-ProjDevFileLock `
    -Path (Join-Path $Toolchain.Context.LockRoot 'app-test.lock') `
    -ControlledRoot $Toolchain.Context.DataRoot `
    -TimeoutSeconds 1800
try {
    foreach ($Project in $RustProjects) {
        $TargetRoot = Assert-ProjDevPathInsideDataRoot `
            -Path (Join-Path $Toolchain.Context.DataRoot "build\$($Project.TargetName)") `
            -DataRoot $Toolchain.Context.DataRoot `
            -Activity "testing the Rust $($Project.Name)"
        & $Toolchain.CargoPath `
            test `
            --locked `
            --offline `
            --manifest-path $Project.ManifestPath `
            --target-dir $TargetRoot
        if ($LASTEXITCODE -ne 0) {
            throw "Rust $($Project.Name) tests failed with exit code $LASTEXITCODE."
        }
    }
} finally {
    $TestLock.Dispose()
}

Write-Host '[PASS] Proj Rust product test suites' -ForegroundColor Green
$global:LASTEXITCODE = 0
