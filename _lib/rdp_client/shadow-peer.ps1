Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'entry.ps1')
. (Join-Path $PSScriptRoot 'shadow-ssh.ps1')

function Invoke-RdpClientShadowRemoteSource {
    param(
        [Parameter(Mandatory = $true)][string]$SshEntryPath,
        [Parameter(Mandatory = $true)][string]$RemoteSource,
        [Parameter(Mandatory = $true)][string]$Operation
    )

    $Invocation = Invoke-RdpClientShadowSshPowerShell `
        -SshEntryPath $SshEntryPath `
        -RemoteSource $RemoteSource
    if ($Invocation.ExitCode -ne 0) {
        $Invocation.Output | Write-Output
        throw "SSH $Operation failed with exit code $($Invocation.ExitCode)."
    }
    return $Invocation
}

function ConvertFrom-RdpClientShadowManageState {
    param([Parameter(Mandatory = $true)][object[]]$Output)

    $Prefix = 'RDP_SHADOW_MANAGE_STATE_V3:'
    $Marker = @($Output | ForEach-Object { [string]$_ } | Where-Object {
        $_.StartsWith($Prefix, [StringComparison]::Ordinal)
    } | Select-Object -Last 1)
    if ($Marker.Count -ne 1) {
        throw 'SSH returned no RDP Shadow peer-state payload.'
    }
    $Bytes = [Convert]::FromBase64String($Marker[0].Substring($Prefix.Length))
    $Json = (New-Object Text.UTF8Encoding($false)).GetString($Bytes)
    return $Json | ConvertFrom-Json
}

function Get-RdpClientShadowManageState {
    param([Parameter(Mandatory = $true)][string]$SshEntryPath)

    $QueryPath = Join-Path $PSScriptRoot 'shadow-manage-query.remote.ps1'
    if (-not [IO.File]::Exists($QueryPath)) {
        throw "RDP Shadow peer-state query not found: $QueryPath"
    }
    $Invocation = Invoke-RdpClientShadowRemoteSource `
        -SshEntryPath $SshEntryPath `
        -RemoteSource ([IO.File]::ReadAllText($QueryPath, [Text.Encoding]::UTF8)) `
        -Operation 'Shadow peer-state query'
    $State = ConvertFrom-RdpClientShadowManageState -Output $Invocation.Output
    return $State
}

function Get-RdpClientNormalizedIpAddress {
    param([Parameter(Mandatory = $true)][Net.IPAddress]$Address)

    if ($Address.IsIPv4MappedToIPv6) {
        return $Address.MapToIPv4()
    }
    return $Address
}

function Assert-RdpClientShadowPeerMatchesEntry {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$State,
        [Parameter(Mandatory = $true)][string]$EntryPath
    )

    $Document = Read-RdpClientEntryDocument -Path $EntryPath
    $HostName = [string]$Document.FullAddress.Host
    $ParsedHost = $null
    if ([Net.IPAddress]::TryParse($HostName, [ref]$ParsedHost)) {
        $Expected = @(Get-RdpClientNormalizedIpAddress -Address $ParsedHost)
    } else {
        try {
            $Expected = @([Net.Dns]::GetHostAddresses($HostName) | ForEach-Object {
                Get-RdpClientNormalizedIpAddress -Address $_
            })
        } catch {
            throw "RDP peer name does not resolve: $HostName"
        }
    }
    if ($Expected.Count -eq 0) {
        throw "RDP peer name does not resolve: $HostName"
    }

    $ParsedPeer = $null
    if (-not [Net.IPAddress]::TryParse([string]$State.PeerAddress, [ref]$ParsedPeer)) {
        throw "Invalid SSH peer address: $($State.PeerAddress)"
    }
    $Peer = Get-RdpClientNormalizedIpAddress -Address $ParsedPeer
    if (-not @($Expected | Where-Object { $_.Equals($Peer) }).Count) {
        $ExpectedText = @($Expected | ForEach-Object { $_.ToString() }) -join ', '
        throw (
            "SSH peer $Peer does not match RDP full address host $HostName " +
            "(resolved: $ExpectedText)."
        )
    }
}

function Assert-RdpClientShadowPeerIdentity {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$State,
        [Parameter(Mandatory = $true)][string]$EntryPath
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$State.ConnectionError)) {
        throw [string]$State.ConnectionError
    }
    Assert-RdpClientShadowPeerMatchesEntry -State $State -EntryPath $EntryPath
}

function Assert-RdpClientShadowPeerMutationState {
    param([Parameter(Mandatory = $true)][pscustomobject]$State)

    if (-not [bool]$State.IsAdministrator) {
        throw 'The SSH account must have an administrator token for peer management.'
    }
    if (-not [bool]$State.Rollback.Valid) {
        throw [string]$State.Rollback.Error
    }
}
