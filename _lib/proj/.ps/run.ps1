$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if ($args.Count -ne 0) {
    throw '.ps does not accept dynamic arguments.'
}

$KernelRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $KernelRoot '_shell\session.ps1')

[void](Enter-ProjInteractiveShellEnvironment -KernelRoot $KernelRoot)
$PowerShellPath = Get-ProjWindowsPowerShellPath
& $PowerShellPath -NoLogo
exit ([int]$LASTEXITCODE)
