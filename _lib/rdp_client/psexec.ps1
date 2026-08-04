[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('status', 'add', 'remove', 'run')]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$SshEntryFile,

    [Parameter(Mandatory = $true)]
    [string]$RdpEntryFile,

    [Parameter(Mandatory = $true)]
    [ValidateRange(0, 32767)]
    [int]$ArgumentCount,

    [string]$CommandName = 'rdp',

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'entry.ps1')
. (Join-Path $PSScriptRoot 'peer-ssh.ps1')

function Get-RdpClientPsExecArguments {
    param([Parameter(Mandatory = $true)][int]$Count)

    $Result = New-Object 'Collections.Generic.List[string]'
    for ($Index = 1; $Index -le $Count; $Index++) {
        $Name = "RDP_PSEXEC_ARG_$Index"
        $Value = [Environment]::GetEnvironmentVariable($Name, 'Process')
        if ($null -eq $Value) {
            throw "PsExec argument $Index was not forwarded by client.cmd."
        }
        $Result.Add($Value)
    }
    return $Result.ToArray()
}

function Get-RdpClientExpectedPeerAddresses {
    param([Parameter(Mandatory = $true)][string]$EntryPath)

    $Document = Read-RdpClientEntryDocument -Path $EntryPath
    $HostName = [string]$Document.FullAddress.Host
    $ParsedHost = $null
    if ([Net.IPAddress]::TryParse($HostName, [ref]$ParsedHost)) {
        $Addresses = @($ParsedHost)
    } else {
        try {
            $Addresses = @([Net.Dns]::GetHostAddresses($HostName))
        } catch {
            throw "RDP peer name does not resolve: $HostName"
        }
    }
    if ($Addresses.Count -eq 0) {
        throw "RDP peer name does not resolve: $HostName"
    }

    return @($Addresses | ForEach-Object {
        if ($_.IsIPv4MappedToIPv6) {
            $_.MapToIPv4().ToString()
        } else {
            $_.ToString()
        }
    } | Sort-Object -Unique)
}

try {
    if ($Action -ne 'run' -and $ArgumentCount -ne 0) {
        throw 'PsExec management commands do not accept native arguments.'
    }
    if ($Action -eq 'run' -and $ArgumentCount -eq 0) {
        throw "PsExec usage: $CommandName .peer psexec -- <native-arguments>"
    }
    if ($Action -eq 'run' -and $DryRun) {
        throw 'PsExec native invocation does not support --dry-run.'
    }

    $Utf8 = New-Object Text.UTF8Encoding($false)
    [Console]::InputEncoding = $Utf8
    [Console]::OutputEncoding = $Utf8
    $OutputEncoding = $Utf8

    $ResolvedSshEntry = Resolve-RdpClientPeerSshEntryPath -Value $SshEntryFile
    $ResolvedRdpEntry = [IO.Path]::GetFullPath($RdpEntryFile)
    Assert-RdpClientPeerSshEntryIsSeparate `
        -SshEntryPath $ResolvedSshEntry `
        -RdpEntryPath $ResolvedRdpEntry

    $Arguments = @()
    if ($Action -eq 'run') {
        $Arguments = @(Get-RdpClientPsExecArguments -Count $ArgumentCount)
    }
    $PayloadJson = [ordered]@{
        Action            = $Action
        DryRun            = $DryRun.IsPresent
        Arguments         = $Arguments
        ExpectedAddresses = @(Get-RdpClientExpectedPeerAddresses `
            -EntryPath $ResolvedRdpEntry)
    } | ConvertTo-Json -Compress -Depth 4
    $PayloadBase64 = [Convert]::ToBase64String($Utf8.GetBytes($PayloadJson))

    $RemoteScriptPath = Join-Path $PSScriptRoot 'psexec.remote.ps1'
    if (-not [IO.File]::Exists($RemoteScriptPath)) {
        throw "RDP peer PsExec script was not found: $RemoteScriptPath"
    }
    $RemoteSource = [IO.File]::ReadAllText($RemoteScriptPath, [Text.Encoding]::UTF8)
    $Marker = '__RDP_CLIENT_PSEXEC_PAYLOAD__'
    if ([regex]::Matches($RemoteSource, [regex]::Escape($Marker)).Count -ne 1) {
        throw 'RDP peer PsExec script has an invalid payload marker.'
    }
    $RemoteSource = $RemoteSource.Replace($Marker, $PayloadBase64)

    $Invocation = Invoke-RdpClientPeerSshPowerShell `
        -SshEntryPath $ResolvedSshEntry `
        -RemoteSource $RemoteSource
    $Invocation.Output | Write-Output
    exit $Invocation.ExitCode
} catch {
    [Console]::Error.WriteLine("[ERROR] $($_.Exception.Message)")
    [Console]::Error.WriteLine(
        "[ERROR] Run `"$CommandName .help`" for peer PsExec usage."
    )
    exit 1
}
