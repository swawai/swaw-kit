$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

if (@($args).Count -gt 0) {
    throw '.dev.status does not accept dynamic arguments.'
}

. (Join-Path $PSScriptRoot '..\setup\_lib\bootstrap.ps1')

$Context = New-ProjDevContextFromEnvironment
$Definition = Get-ProjDevBunDefinition
if ($null -eq $Definition) {
    Write-Host '[OFF] bun is disabled.' -ForegroundColor DarkGray
    $global:LASTEXITCODE = 0
    return
}

$Trust = Get-ProjDevBunTrustStatus `
    -Context $Context `
    -Definition $Definition
$Ready = $null -ne $Trust.Metadata -and
    (Test-ProjDevInstalled -Context $Context -Definition $Definition)
$State = if ($Ready) { 'ready' } else { 'missing' }
$Color = if ($Ready) { 'Green' } else { 'Yellow' }
Write-Host (
    "[{0}] bun {1}  {2}  {3}" -f
        $State.ToUpperInvariant(),
        $Definition.Version,
        $Trust.Level,
        $Trust.Message
) -ForegroundColor $Color
Write-ProjDevBunTrustWarning `
    -Context $Context `
    -Definition $Definition

$global:LASTEXITCODE = 0
