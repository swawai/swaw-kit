[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$engine = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$suites = @(
    "smoke.ps1",
    "smoke.access-mode.ps1",
    "smoke.https-auth.ps1",
    "smoke.https-credential-guard.ps1",
    "smoke.https-login.ps1",
    "smoke.remote-protocol.ps1",
    "smoke.editor.ps1",
    "smoke.sync.ps1"
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

Write-Host "[OK]  All Git identity kit smoke suites passed."
