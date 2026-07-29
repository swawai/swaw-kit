[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'bun.release.ps1')
& (Join-Path $PSScriptRoot 'bun.install.ps1')
& (Join-Path $PSScriptRoot 'bun.status.ps1')
& (Join-Path $PSScriptRoot 'bun.command.ps1')

Write-Host '[PASS] Proj Bun test suite' -ForegroundColor Green
$global:LASTEXITCODE = 0
