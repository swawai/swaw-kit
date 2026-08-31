[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$engine = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$suites = @(
    'smoke.ps1',
    'smoke.runtime.ps1'
)

foreach ($suite in $suites) {
    $path = Join-Path $PSScriptRoot $suite
    Write-Host "[RUN] $suite"
    & $engine -NoLogo -NoProfile -ExecutionPolicy Bypass -File $path
    if ($LASTEXITCODE -ne 0) {
        throw "$suite failed with exit code $LASTEXITCODE."
    }
    Write-Host "[OK]  $suite"
}

Write-Host '[OK]  All GitHub CLI kit smoke suites passed.' -ForegroundColor Green
