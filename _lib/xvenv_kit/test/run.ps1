$ErrorActionPreference = 'Stop'

$PowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
foreach ($TestName in @('module-loader.ps1', 'smoke.ps1')) {
    $TestPath = Join-Path $PSScriptRoot $TestName
    & $PowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $TestPath
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}
exit 0
