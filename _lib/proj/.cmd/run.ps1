$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if ($args.Count -ne 0) {
    throw '.cmd does not accept dynamic arguments.'
}

$KernelRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $KernelRoot '_core\engine.ps1')
. (Join-Path $KernelRoot '_shell\session.ps1')

$ProjectContext = Get-ProjProjectContext `
    -ProjHome ([string]$env:SWAWKIT_PROJ_HOME)
[void](Import-ProjDevelopmentEnvironment `
    -ProjectContext $ProjectContext)
[void](Enter-ProjInteractiveShellEnvironment -KernelRoot $KernelRoot)
$CmdPath = Get-ProjSystemCmdPath
& $CmdPath /d
exit ([int]$LASTEXITCODE)
