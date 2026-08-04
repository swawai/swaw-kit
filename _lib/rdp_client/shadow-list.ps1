[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$SshEntryFile,

    [Parameter(Mandatory = $true)]
    [string]$RdpEntryFile,

    [string]$CommandName = 'rdp'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'peer-ssh.ps1')

try {
    $Utf8NoBom = New-Object Text.UTF8Encoding($false)
    [Console]::InputEncoding = $Utf8NoBom
    [Console]::OutputEncoding = $Utf8NoBom
    $OutputEncoding = $Utf8NoBom

    $ResolvedSshEntry = Resolve-RdpClientPeerSshEntryPath -Value $SshEntryFile
    $ResolvedRdpEntry = [IO.Path]::GetFullPath($RdpEntryFile)
    Assert-RdpClientPeerSshEntryIsSeparate `
        -SshEntryPath $ResolvedSshEntry `
        -RdpEntryPath $ResolvedRdpEntry

    $RemoteSource = @'
$ProgressPreference = 'SilentlyContinue'
$Utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = $Utf8
[Console]::OutputEncoding = $Utf8
$OutputEncoding = $Utf8
$NativeSystemDirectory = if (
    [Environment]::Is64BitOperatingSystem -and
    -not [Environment]::Is64BitProcess
) {
    Join-Path $env:SystemRoot 'Sysnative'
} else {
    Join-Path $env:SystemRoot 'System32'
}
$Quser = Join-Path $NativeSystemDirectory 'quser.exe'
if (-not [IO.File]::Exists($Quser)) {
    throw "quser.exe was not found: $Quser"
}
& $Quser
exit $LASTEXITCODE
'@
    $Invocation = Invoke-RdpClientPeerSshPowerShell `
        -SshEntryPath $ResolvedSshEntry `
        -RemoteSource $RemoteSource
    $Invocation.Output | Write-Output
    if ($Invocation.ExitCode -ne 0) {
        throw "SSH session query failed with exit code $($Invocation.ExitCode)."
    }
    exit 0
} catch {
    [Console]::Error.WriteLine("[ERROR] $($_.Exception.Message)")
    [Console]::Error.WriteLine(
        "[ERROR] Run `"$CommandName .help`" for Shadow setup guidance."
    )
    exit 1
}
