[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot '..\_core\smoke.ps1')
& (Join-Path $PSScriptRoot 'smoke-entry.ps1')
& (Join-Path $PSScriptRoot 'bun.ps1')
& (Join-Path $PSScriptRoot 'msvc.ps1')
& (Join-Path $PSScriptRoot 'rust.ps1')

Write-Host '[PASS] Proj test suite' -ForegroundColor Green
$global:LASTEXITCODE = 0
