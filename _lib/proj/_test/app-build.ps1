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
. (Join-Path $RepoRoot '_lib\proj\_bootstrap\toolchain.ps1')
$BuildScript = Join-Path $RepoRoot '_lib\proj\_app\build.ps1'
$ModuleManifest = Join-Path $RepoRoot '_lib\proj\system\module\Cargo.toml'
$DevManifest = Join-Path $RepoRoot '_lib\proj\system\dev\Cargo.toml'
$TemporaryRoot = Join-Path $RepoRoot (
    "data\_test\swawkit-proj-app-build-$([Guid]::NewGuid().ToString('N'))"
)
$FakeCargo = Join-Path $TemporaryRoot 'cargo.cmd'
$TargetRoot = Join-Path $TemporaryRoot 'target with spaces'
$ModuleTargetRoot = Join-Path $TemporaryRoot 'module target with spaces'
$DevTargetRoot = Join-Path $TemporaryRoot 'dev target with spaces'
$RuntimePath = Join-Path $RepoRoot '_lib\proj\_bin\current'
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
set "manifest="
:next
if "%~1"=="" goto build
if "%~1"=="--manifest-path" (
  set "manifest=%~2"
  shift
)
if "%~1"=="--target-dir" (
  set "target=%~2"
  shift
)
shift
goto next
:build
if not defined target exit /b 41
if not exist "%target%\release" mkdir "%target%\release"
echo %target% | findstr /i /l /c:"module target with spaces" >nul
if not errorlevel 1 goto module
echo %target% | findstr /i /l /c:"dev target with spaces" >nul
if not errorlevel 1 goto dev
copy /y "%ComSpec%" "%target%\release\swawkit-proj.exe" >nul
copy /y "%ComSpec%" "%target%\release\swawkit-proj-host.exe" >nul
exit /b %errorlevel%
:module
copy /y "%ComSpec%" "%target%\release\swawkit-proj-module.exe" >nul
exit /b %errorlevel%
:dev
copy /y "%ComSpec%" "%target%\release\swawkit-proj-dev.exe" >nul
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
    $ModuleOutput = @(Invoke-ProjBootstrapRustProductBuild `
        -ProductName 'Module' `
        -CandidateName 'swawkit-proj-module.exe' `
        -CargoPath $FakeCargo `
        -ManifestPath $ModuleManifest `
        -TargetDirectory $ModuleTargetRoot)
    $DevOutput = @(Invoke-ProjBootstrapRustProductBuild `
        -ProductName 'Dev' `
        -CandidateName 'swawkit-proj-dev.exe' `
        -CargoPath $FakeCargo `
        -ManifestPath $DevManifest `
        -TargetDirectory $DevTargetRoot)
    $Candidate = Join-Path $TargetRoot 'release\swawkit-proj.exe'
    $HostCandidate = Join-Path $TargetRoot 'release\swawkit-proj-host.exe'
    $DevCandidate = Join-Path $DevTargetRoot (
        'release\swawkit-proj-dev.exe'
    )
    $ModuleCandidate = Join-Path $ModuleTargetRoot (
        'release\swawkit-proj-module.exe'
    )
    Assert-ProjAppBuildTest `
        -Condition (
            [IO.File]::Exists($Candidate) -and
            [IO.File]::Exists($HostCandidate) -and
            [IO.File]::Exists($ModuleCandidate) -and
            [IO.File]::Exists($DevCandidate) -and
            (Get-Item -LiteralPath $Candidate).Length -gt 0
        ) `
        -Message 'the App build primitive did not produce its candidate'
    Assert-ProjAppBuildTest `
        -Condition (@($Output) -contains $Candidate) `
        -Message 'the App build primitive did not report its candidate path'
    Assert-ProjAppBuildTest `
        -Condition (@($Output) -contains $HostCandidate) `
        -Message 'the App build primitive did not report its Host candidate path'
    Assert-ProjAppBuildTest `
        -Condition (@($DevOutput) -contains $DevCandidate) `
        -Message 'the Dev build primitive did not report its candidate path'
    Assert-ProjAppBuildTest `
        -Condition (@($ModuleOutput) -contains $ModuleCandidate) `
        -Message 'the Module build primitive did not report its candidate path'
    if ($null -eq $RuntimeHash) {
        Assert-ProjAppBuildTest `
            -Condition (-not [IO.File]::Exists($RuntimePath)) `
            -Message 'the App build primitive published a runtime selector'
    } else {
        Assert-ProjAppBuildTest `
            -Condition (
                (Get-FileHash `
                    -LiteralPath $RuntimePath `
                    -Algorithm SHA256).Hash -ceq $RuntimeHash
            ) `
            -Message 'the App build primitive replaced the runtime selector'
    }
} finally {
    if ([IO.Directory]::Exists($TemporaryRoot)) {
        [IO.Directory]::Delete($TemporaryRoot, $true)
    }
}

Write-Host '[PASS] Proj App build boundary' -ForegroundColor Green
$global:LASTEXITCODE = 0
