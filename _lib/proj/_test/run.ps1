[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot '..\_core\smoke.ps1')
& (Join-Path $PSScriptRoot 'optional-action-root.ps1')
& (Join-Path $PSScriptRoot 'smoke-entry.ps1')
& (Join-Path $PSScriptRoot 'entry-data-root.ps1')
& (Join-Path $PSScriptRoot 'claim-timeout.ps1')
& (Join-Path $PSScriptRoot 'core-environment.ps1')
& (Join-Path $PSScriptRoot 'launcher-policy.ps1')
& (Join-Path $PSScriptRoot 'shell.ps1')
& (Join-Path $PSScriptRoot 'install-recovery.ps1')
& (Join-Path $PSScriptRoot 'bun.ps1')
& (Join-Path $PSScriptRoot 'pwsh.ps1')
& (Join-Path $PSScriptRoot 'msvc.ps1')
& (Join-Path $PSScriptRoot 'msvc.cache.ps1')
& (Join-Path $PSScriptRoot 'rust.ps1')
& (Join-Path $PSScriptRoot 'rust.strict.ps1')

Write-Host '[PASS] Proj test suite' -ForegroundColor Green
$global:LASTEXITCODE = 0
