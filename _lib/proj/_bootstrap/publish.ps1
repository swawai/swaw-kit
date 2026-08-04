[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

. (Join-Path $PSScriptRoot '_lib\layout.ps1')
$Layout = Get-ProjBootstrapLayout
$FoundationPath = Join-Path $Layout.KernelRoot (
    '.dev\setup\_lib\foundation.ps1'
)
. $FoundationPath
$CandidatePath = Assert-ProjDevPathInsideDataRoot `
    -Path (Join-Path $Layout.BuildRoot 'release\swawkit-proj.exe') `
    -DataRoot $Layout.BootstrapDataRoot `
    -Activity 'publishing the Bootstrap application'
if (-not [IO.File]::Exists($CandidatePath) -or
    (Get-Item -LiteralPath $CandidatePath).Length -le 0) {
    throw "The Bootstrap application candidate is missing or empty: $CandidatePath"
}
if ([IO.File]::Exists($Layout.RuntimePath)) {
    throw (
        'Bootstrap publication refuses to replace an existing shared Core: ' +
        $Layout.RuntimePath
    )
}

$RuntimeDirectory = Split-Path -Path $Layout.RuntimePath -Parent
$RuntimeDirectoryItem = Get-Item `
    -LiteralPath $RuntimeDirectory `
    -Force `
    -ErrorAction SilentlyContinue
if ($null -ne $RuntimeDirectoryItem -and
    (-not $RuntimeDirectoryItem.PSIsContainer -or
        ($RuntimeDirectoryItem.Attributes -band
            [IO.FileAttributes]::ReparsePoint) -ne 0)) {
    throw "The shared runtime directory is unsafe: $RuntimeDirectory"
}
if ($null -eq $RuntimeDirectoryItem) {
    [void][IO.Directory]::CreateDirectory($RuntimeDirectory)
}
$StagedPath = Join-Path $RuntimeDirectory (
    ".swawkit-proj.$([Guid]::NewGuid().ToString('N')).tmp"
)
try {
    [IO.File]::Copy($CandidatePath, $StagedPath, $false)
    [IO.File]::Move($StagedPath, $Layout.RuntimePath)
} finally {
    if ([IO.File]::Exists($StagedPath)) {
        [IO.File]::Delete($StagedPath)
    }
}

Write-Host "[PUBLISHED] $($Layout.RuntimePath)" -ForegroundColor Green
