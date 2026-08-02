$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

if ($args.Count -ne 0) {
    throw 'proj.build.app does not accept dynamic arguments.'
}

$KernelRoot = [IO.Path]::GetFullPath(
    (Join-Path ([string]$env:SWAWKIT_PROJ_HOME) '_lib\proj')
)
. (Join-Path $KernelRoot '_core\engine.ps1')
. (Join-Path $KernelRoot '.dev\setup\_modules\rust\runtime.ps1')

$ManifestPath = Join-Path $KernelRoot '_app\Cargo.toml'
$TargetDirectory = Join-Path (
    [string]$env:SWAWKIT_PROJ_DATA_ROOT
) '_build\app'
[string[]]$CargoArguments = @(
    'build',
    '--locked',
    '--release',
    '--manifest-path',
    $ManifestPath,
    '--target-dir',
    $TargetDirectory
)
$ExitCode = Invoke-ProjDevRustCommand `
    -ExecutableName 'cargo.exe' `
    -Arguments $CargoArguments
if ($ExitCode -eq 0) {
    Write-Host (Join-Path $TargetDirectory (
        'release\swawkit-proj.exe'
    ))
}
exit ([int]$ExitCode)
