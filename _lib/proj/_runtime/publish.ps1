[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CandidateCorePath,
    [Parameter(Mandatory = $true)][string]$CandidateHostPath,
    [Parameter(Mandatory = $true)][string]$CandidateModulePath,
    [Parameter(Mandatory = $true)][string]$CandidateDevPath,
    [Parameter(Mandatory = $true)][string]$CommandRuntimeId,
    [Parameter(Mandatory = $true)][string]$ProjHome,
    [Parameter(Mandatory = $true)][string]$CandidateRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$KernelRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'release.ps1')

$CandidateCorePath = Assert-ProjDevPathInsideDataRoot `
    -Path $CandidateCorePath `
    -DataRoot $CandidateRoot `
    -Activity 'publishing the Bootstrap Core'
$CandidateHostPath = Assert-ProjDevPathInsideDataRoot `
    -Path $CandidateHostPath `
    -DataRoot $CandidateRoot `
    -Activity 'publishing the Bootstrap Host'
$CandidateModulePath = Assert-ProjDevPathInsideDataRoot `
    -Path $CandidateModulePath `
    -DataRoot $CandidateRoot `
    -Activity 'publishing the Bootstrap Module executable'
$CandidateDevPath = Assert-ProjDevPathInsideDataRoot `
    -Path $CandidateDevPath `
    -DataRoot $CandidateRoot `
    -Activity 'publishing the Bootstrap Dev runtime'
$ReleaseSet = New-ProjRuntimeReleaseSetFromFiles `
    -Artifacts ([ordered]@{
        'swawkit-proj.exe' = $CandidateCorePath
        'swawkit-proj-host.exe' = $CandidateHostPath
        'swawkit-proj-module.exe' = $CandidateModulePath
        'swawkit-proj-dev.exe' = $CandidateDevPath
    }) `
    -CommandRuntimeId $CommandRuntimeId
Publish-ProjRuntimeReleaseSet `
    -ReleaseSet $ReleaseSet `
    -ProjHome $ProjHome `
    -CacheDataRoot (Join-Path $ProjHome 'data\proj_cache') | Out-Null
