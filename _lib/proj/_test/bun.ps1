[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$DevPath
)

$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'bun.release.ps1')
& (Join-Path $PSScriptRoot 'bun.latest.ps1')
& (Join-Path $PSScriptRoot 'bun.install.ps1') `
    -DevPath $DevPath
& (Join-Path $PSScriptRoot 'bun.status.ps1') `
    -DevPath $DevPath
& (Join-Path $PSScriptRoot 'bun.command.ps1') `
    -DevPath $DevPath

Write-Host '[PASS] Proj Bun test suite' -ForegroundColor Green
$global:LASTEXITCODE = 0
