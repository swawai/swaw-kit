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
. (Join-Path $PSScriptRoot 'shadow-ssh.ps1')

try {
    $Utf8NoBom = New-Object Text.UTF8Encoding($false)
    [Console]::InputEncoding = $Utf8NoBom
    [Console]::OutputEncoding = $Utf8NoBom
    $OutputEncoding = $Utf8NoBom

    $ResolvedSshEntry = Resolve-RdpClientShadowSshEntryPath -Value $SshEntryFile
    $ResolvedRdpEntry = [IO.Path]::GetFullPath($RdpEntryFile)
    Assert-RdpClientShadowSshEntryIsSeparate `
        -SshEntryPath $ResolvedSshEntry `
        -RdpEntryPath $ResolvedRdpEntry

    $RemoteSource = @'
$ProgressPreference = 'SilentlyContinue'
$Utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = $Utf8
[Console]::OutputEncoding = $Utf8
$OutputEncoding = $Utf8
$Quser = Join-Path $env:SystemRoot 'System32\quser.exe'
if (-not [IO.File]::Exists($Quser)) {
    throw "quser.exe was not found: $Quser"
}
& $Quser
exit $LASTEXITCODE
'@
    $Invocation = Invoke-RdpClientShadowSshPowerShell `
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
