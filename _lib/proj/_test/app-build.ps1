[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Assert-ProjAppBuildTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$BuildScript = Join-Path $RepoRoot '_lib\proj\_app\build.ps1'
$TemporaryRoot = Join-Path $RepoRoot (
    "data\_test\swawkit-proj-app-build-$([Guid]::NewGuid().ToString('N'))"
)
$FakeCargo = Join-Path $TemporaryRoot 'cargo.cmd'
$TargetRoot = Join-Path $TemporaryRoot 'target with spaces'
$RuntimePath = Join-Path $RepoRoot '_lib\proj\_bin\swawkit-proj.exe'
$RuntimeHash = if ([IO.File]::Exists($RuntimePath)) {
    (Get-FileHash -LiteralPath $RuntimePath -Algorithm SHA256).Hash
} else {
    $null
}

try {
    [void][IO.Directory]::CreateDirectory($TemporaryRoot)
    $Fixture = @'
@echo off
setlocal
set "target="
:next
if "%~1"=="" goto build
if "%~1"=="--target-dir" (
  set "target=%~2"
  shift
)
shift
goto next
:build
if not defined target exit /b 41
if not exist "%target%\release" mkdir "%target%\release"
copy /y "%ComSpec%" "%target%\release\swawkit-proj.exe" >nul
exit /b %errorlevel%
'@
    [IO.File]::WriteAllText(
        $FakeCargo,
        $Fixture,
        [Text.ASCIIEncoding]::new()
    )

    $Output = @(& $BuildScript `
        -CargoPath $FakeCargo `
        -TargetDirectory $TargetRoot)
    $Candidate = Join-Path $TargetRoot 'release\swawkit-proj.exe'
    Assert-ProjAppBuildTest `
        -Condition (
            [IO.File]::Exists($Candidate) -and
            (Get-Item -LiteralPath $Candidate).Length -gt 0
        ) `
        -Message 'the App build primitive did not produce its candidate'
    Assert-ProjAppBuildTest `
        -Condition (@($Output) -contains $Candidate) `
        -Message 'the App build primitive did not report its candidate path'
    if ($null -eq $RuntimeHash) {
        Assert-ProjAppBuildTest `
            -Condition (-not [IO.File]::Exists($RuntimePath)) `
            -Message 'the App build primitive published a new shared Core'
    } else {
        Assert-ProjAppBuildTest `
            -Condition (
                (Get-FileHash `
                    -LiteralPath $RuntimePath `
                    -Algorithm SHA256).Hash -ceq $RuntimeHash
            ) `
            -Message 'the App build primitive replaced the shared Core'
    }
} finally {
    if ([IO.Directory]::Exists($TemporaryRoot)) {
        [IO.Directory]::Delete($TemporaryRoot, $true)
    }
}

Write-Host '[PASS] Proj App build boundary' -ForegroundColor Green
$global:LASTEXITCODE = 0
