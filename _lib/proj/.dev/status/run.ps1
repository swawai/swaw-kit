$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

if (@($args).Count -gt 0) {
    throw '.dev.status does not accept dynamic arguments.'
}

. (Join-Path $PSScriptRoot '..\setup\_lib\bootstrap.ps1')

$Context = New-ProjDevContextFromEnvironment
$BunDefinition = Get-ProjDevBunDefinition
if ($null -eq $BunDefinition) {
    Write-Host '[OFF] bun is disabled.' -ForegroundColor DarkGray
} else {
    $Trust = Get-ProjDevBunTrustStatus `
        -Context $Context `
        -Definition $BunDefinition
    $Ready = $null -ne $Trust.Metadata -and
        (Test-ProjDevInstalled `
            -Context $Context `
            -Definition $BunDefinition)
    $State = if ($Ready) { 'ready' } else { 'missing' }
    $Color = if ($Ready) { 'Green' } else { 'Yellow' }
    Write-Host (
        "[{0}] bun {1}  {2}  {3}" -f
            $State.ToUpperInvariant(),
            $BunDefinition.Version,
            $Trust.Level,
            $Trust.Message
    ) -ForegroundColor $Color
    Write-ProjDevBunTrustWarning `
        -Context $Context `
        -Definition $BunDefinition
}

$MsvcDefinition = Get-ProjDevMsvcDefinition
if ($null -eq $MsvcDefinition) {
    Write-Host '[OFF] msvc is disabled.' -ForegroundColor DarkGray
} else {
    $MsvcMetadata = Get-ProjDevMsvcValidMetadata `
        -Context $Context `
        -Definition $MsvcDefinition
    $MsvcReady = $null -ne $MsvcMetadata -and
        (Test-ProjDevMsvcInstalled `
            -Context $Context `
            -Definition $MsvcDefinition)
    $MsvcState = if ($MsvcReady) { 'READY' } else { 'MISSING' }
    $MsvcColor = if ($MsvcReady) { 'Green' } else { 'Yellow' }
    $MsvcVersion = if ($MsvcReady) {
        "tool $($MsvcMetadata.toolVersion), SDK $($MsvcMetadata.sdkVersion)"
    } else {
        'not installed'
    }
    Write-Host (
        "[$MsvcState] msvc channel $($MsvcDefinition.Channel)  " +
        "microsoft-manifest  $MsvcVersion"
    ) -ForegroundColor $MsvcColor
}

$global:LASTEXITCODE = 0
