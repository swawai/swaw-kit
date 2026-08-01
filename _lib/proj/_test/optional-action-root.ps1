[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ProjRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $ProjRoot '_core\engine.ps1')

$MissingActionRoot = Join-Path (
    [IO.Path]::GetTempPath()
) "proj-missing-actions-$([Guid]::NewGuid().ToString('N'))"
$RejectedAsMissingCommand = $false
try {
    [void](Resolve-ProjCommand `
        -KernelRoot $ProjRoot `
        -ActionRoot $MissingActionRoot `
        -Address 'bun')
} catch {
    $RejectedAsMissingCommand = $_.Exception.Message -ceq (
        'Command not found: bun'
    )
}
if (-not $RejectedAsMissingCommand) {
    throw (
        'Proj optional Action Root test failed: a missing .swaw directory ' +
        'did not resolve as a missing Action command.'
    )
}

Write-Host '[PASS] Proj optional Action Root test' -ForegroundColor Green
$global:LASTEXITCODE = 0
