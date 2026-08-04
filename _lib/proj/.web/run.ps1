$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if ($args.Count -ne 0) {
    throw '.web does not accept dynamic arguments.'
}

$ProjHome = [string]$env:SWAWKIT_HOME
$ProjectRoot = [string]$env:SWAWKIT_PROJ_TARGET_PROJECT_ROOT
$CommandName = [string]$env:SWAWKIT_PROJ_ENTRY_COMMAND
if ([string]::IsNullOrWhiteSpace($ProjHome) -or
    [string]::IsNullOrWhiteSpace($ProjectRoot) -or
    [string]::IsNullOrWhiteSpace($CommandName)) {
    throw 'The project runtime context is incomplete.'
}

$AppPath = Join-Path $ProjHome '_lib\proj\_bin\swawkit-proj.exe'
if (-not [IO.File]::Exists($AppPath)) {
    throw (
        "Swaw Kit Proj is not built. Run '$CommandName " +
        "proj.build.app' first."
    )
}

$StartInfo = [Diagnostics.ProcessStartInfo]::new()
$StartInfo.FileName = $AppPath
$StartInfo.WorkingDirectory = $ProjectRoot
$StartInfo.UseShellExecute = $false
$StartInfo.CreateNoWindow = $true
$StartInfo.EnvironmentVariables['SWAWKIT_PROJ_LAUNCH_MODE'] = 'internal-host'
$Process = [Diagnostics.Process]::Start($StartInfo)
if ($null -eq $Process) {
    throw "Failed to start Swaw Kit Proj: $AppPath"
}
try {
    Write-Host "Swaw Kit Proj started (PID $($Process.Id))."
} finally {
    $Process.Dispose()
}
