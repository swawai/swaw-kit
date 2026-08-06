[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ProjRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $ProjRoot '_core\data-root-claim.ps1')

$Claim = [pscustomobject]@{
    Kind = 'ClaimCurrent'
    EntryName = 'fixture'
    EntryFile = 'C:\fixture.exe'
    VolumeId = 'volume'
    FileId = 'file'
    DataRoot = 'C:\data\proj.fixture'
    SourceDataRoot = ''
    Reason = 'identity record is missing'
}

$Stopwatch = [Diagnostics.Stopwatch]::StartNew()
$Failure = $null
try {
    Confirm-ProjDataRootClaim -Claim $Claim
} catch {
    $Failure = $_.Exception
} finally {
    $Stopwatch.Stop()
}

if ($null -eq $Failure) {
    throw 'Assertion failed: legacy Core unexpectedly approved a claim'
}
if ($Stopwatch.Elapsed.TotalSeconds -ge 1) {
    throw 'Assertion failed: legacy Core blocked while rejecting a claim'
}
if (-not $Failure.Message.Contains('fixture ..entry.claim --yes')) {
    throw 'Assertion failed: legacy Core did not point to the explicit claim command'
}

Write-Host '[PASS] Proj non-interactive claim boundary' -ForegroundColor Green
$global:LASTEXITCODE = 0
