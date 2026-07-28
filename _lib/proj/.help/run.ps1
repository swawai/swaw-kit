$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

if ($args.Count -ne 0) {
    throw "Command '.help' does not accept tail arguments."
}

. (Join-Path $PSScriptRoot '..\_core\engine.ps1')

$ProjectContext = Get-ProjProjectContext
$TargetAddress = [Environment]::GetEnvironmentVariable(
    'SWAWKIT_HELP_TARGET_ADDRESS',
    'Process'
)
if ($null -eq $TargetAddress) {
    $TargetAddress = ''
}

Write-ProjHelp `
    -KernelRoot ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))) `
    -ActionRoot $ProjectContext.ActionRoot `
    -CommandName $ProjectContext.EntryCommand `
    -TargetAddress $TargetAddress
