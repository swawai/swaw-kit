$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if ($args.Count -ne 0) {
    throw 'proj.build.app does not accept dynamic arguments.'
}

$BuildPath = Join-Path (
    [string]$env:SWAWKIT_PROJ_HOME
) '_lib\proj\_app\build.ps1'
if (-not [IO.File]::Exists($BuildPath)) {
    throw "The Swaw Kit Proj application build script is missing: $BuildPath"
}

& $BuildPath
exit $LASTEXITCODE
