[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$EntryFile,

    [Parameter(Mandatory = $true)]
    [string]$SessionId,

    [switch]$Control,

    [switch]$NoConsentPrompt
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'entry.ps1')

try {
    $Utf8NoBom = New-Object Text.UTF8Encoding($false)
    [Console]::OutputEncoding = $Utf8NoBom
    $OutputEncoding = $Utf8NoBom

    $ResolvedSessionId = Resolve-RdpClientShadowSessionId -Value $SessionId
    if ($null -eq $ResolvedSessionId) {
        throw 'Shadow session ID is required.'
    }

    $ResolvedEntry = [IO.Path]::GetFullPath($EntryFile)
    $HostAlias = Resolve-RdpClientHostAlias -Value $env:RDP_HOST_ALIAS
    $Document = Read-RdpClientEntryDocument -Path $ResolvedEntry
    $Target = Resolve-RdpClientConnectionTarget `
        -Document $Document `
        -HostAlias $HostAlias
    Assert-RdpClientHostAliasResolves -HostAlias $HostAlias

    $MstscArguments = New-RdpClientShadowMstscArgumentList `
        -Target $Target `
        -ShadowSessionId $ResolvedSessionId `
        -Control:$Control `
        -NoConsentPrompt:$NoConsentPrompt
    $Mstsc = Get-Command 'mstsc.exe' -ErrorAction Stop
    Start-Process `
        -FilePath $Mstsc.Source `
        -ArgumentList $MstscArguments |
        Out-Null

    $ShadowTarget = Resolve-RdpClientShadowConnectionTarget -Target $Target
    $Access = if ($Control) { 'control' } else { 'view only' }
    $Consent = if ($NoConsentPrompt) { 'no consent prompt' } else { 'user consent' }
    Write-Host "[RDP] Target:    $ShadowTarget"
    Write-Host "[RDP] Shadow:    session $ResolvedSessionId ($Access; $Consent)"
    Write-Host '[RDP] Started mstsc.exe.'
    exit 0
} catch {
    [Console]::Error.WriteLine("[ERROR] $($_.Exception.Message)")
    exit 1
}
