[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

. (Join-Path $PSScriptRoot 'toolchain.ps1')

Invoke-ProjBootstrapToolchain -Action {
    param($Toolchain, $Layout)

    Write-Host (
        '[READY] Bootstrap Native builder environment {0}' -f
        $Toolchain.EnvironmentRevision
    ) -ForegroundColor Green
}

$global:LASTEXITCODE = 0
