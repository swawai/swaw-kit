$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

if ($args.Count -ne 0) {
    throw 'proj.build.app.bootstrap does not accept dynamic arguments.'
}

$BuildPath = Join-Path (
    [string]$env:SWAWKIT_HOME
) '_lib\proj\_bootstrap\build.ps1'
if (-not [IO.File]::Exists($BuildPath)) {
    throw "The Swaw Kit Proj Bootstrap build is missing: $BuildPath"
}

& $BuildPath
