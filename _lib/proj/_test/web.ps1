[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$WebRoot = Join-Path $RepoRoot '_lib\proj\_app\web'
$BunInstallsRoot = Join-Path $RepoRoot (
    'data\proj.swawkit\modules\system\dev\setup\export\bun\installs'
)

if (-not [IO.Directory]::Exists($BunInstallsRoot)) {
    throw "Web tests require an installed Bun runtime. Run '.\swawkit.exe .dev/setup'."
}

$BunExecutables = @(
    Get-ChildItem -LiteralPath $BunInstallsRoot -Directory |
        Sort-Object -Property Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'bun.exe' } |
        Where-Object { [IO.File]::Exists($_) }
)
if ($BunExecutables.Count -eq 0) {
    throw "Web tests require an installed Bun executable below '$BunInstallsRoot'. Run '.\swawkit.exe .dev/setup'."
}
$BunExecutable = [string]$BunExecutables[0]

Push-Location $WebRoot
try {
    & $BunExecutable test
    if ($LASTEXITCODE -ne 0) {
        throw "Web tests failed with exit code $LASTEXITCODE."
    }
} finally {
    Pop-Location
}

Write-Host '[PASS] Proj Web test suite' -ForegroundColor Green
$global:LASTEXITCODE = 0
