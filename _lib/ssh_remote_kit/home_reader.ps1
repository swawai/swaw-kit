<#
.SYNOPSIS
  Print the remote user's HOME directory.
#>

param(
    [Parameter(Mandatory=$true)] [int]$Port,
    [Parameter(Mandatory=$true)] [string]$RemoteHost,
    [Parameter(Mandatory=$true)] [string]$RemoteUser,
    [Parameter(Mandatory=$true)] [string]$SshKeyPath
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "ps_common.ps1")

$remoteKit = Initialize-RemoteKitContext `
    -Port $Port `
    -RemoteHost $RemoteHost `
    -RemoteUser $RemoteUser `
    -SshKeyPath $SshKeyPath `
    -ModuleRoot $PSScriptRoot `
    -UploadSubdir "home_reader"

$args = @("-i", $remoteKit.SshKeyPath) +
    $remoteKit.SshCommonOpts +
    $remoteKit.SshCommandOpts +
    @("-p", $remoteKit.Port, $remoteKit.RemoteTarget, 'echo $HOME')

$process = New-Object System.Diagnostics.Process
$process.StartInfo.FileName = $remoteKit.SshExe
$process.StartInfo.Arguments = Join-RemoteKitProcessArguments $args
$process.StartInfo.UseShellExecute = $false
$process.StartInfo.CreateNoWindow = $true
$process.StartInfo.RedirectStandardOutput = $true
$process.StartInfo.RedirectStandardError = $true

$process.Start() | Out-Null
$stdout = $process.StandardOutput.ReadToEnd()
$stderr = $process.StandardError.ReadToEnd()
$process.WaitForExit()

if ($process.ExitCode -ne 0) {
    foreach ($line in ($stderr -split '\r?\n')) {
        if ($line) { Write-Error $line }
    }
    exit $process.ExitCode
}

$homeLine = $stdout -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($homeLine) -or $homeLine -eq '$HOME') {
    Write-Error "Remote HOME is empty or unresolved."
    exit 1
}

Write-Output $homeLine
exit 0
