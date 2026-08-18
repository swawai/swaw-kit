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
. (Join-Path $RepoRoot '_lib\proj\_toolchain\bootstrap.ps1')
$BuildScript = Join-Path $RepoRoot '_lib\proj\_app\build.ps1'
$ModuleManifest = Join-Path $RepoRoot '_lib\proj\system\module\Cargo.toml'
$TemporaryRoot = Join-Path $RepoRoot (
    "data\_test\swawkit-proj-app-build-$([Guid]::NewGuid().ToString('N'))"
)
$FakeCargo = Join-Path $TemporaryRoot 'cargo.cmd'
$TargetRoot = Join-Path $TemporaryRoot 'target with spaces'
$ModuleTargetRoot = Join-Path $TemporaryRoot 'module target with spaces'
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
copy /y "%ComSpec%" "%target%\release\swawkit-proj.exe" >nul
copy /y "%ComSpec%" "%target%\release\swawkit-proj-host.exe" >nul
copy /y "%ComSpec%" "%target%\release\swawkit-proj-toolchain.exe" >nul
exit /b %errorlevel%
:module
copy /y "%ComSpec%" "%target%\release\swawkit-proj-module.exe" >nul
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
    $ModuleOutput = @(Invoke-ProjBootstrapModuleBuild `
        -CargoPath $FakeCargo `
        -ManifestPath $ModuleManifest `
        -TargetDirectory $ModuleTargetRoot)
    $Candidate = Join-Path $TargetRoot 'release\swawkit-proj.exe'
    $HostCandidate = Join-Path $TargetRoot 'release\swawkit-proj-host.exe'
    $ToolchainCandidate = Join-Path $TargetRoot (
        'release\swawkit-proj-toolchain.exe'
    )
    $ModuleCandidate = Join-Path $ModuleTargetRoot (
        'release\swawkit-proj-module.exe'
    )
    Assert-ProjAppBuildTest `
        -Condition (
            [IO.File]::Exists($Candidate) -and
            [IO.File]::Exists($HostCandidate) -and
            [IO.File]::Exists($ModuleCandidate) -and
            [IO.File]::Exists($ToolchainCandidate) -and
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
        -Condition (@($Output) -contains $ToolchainCandidate) `
        -Message 'the App build primitive did not report its Toolchain candidate path'
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
