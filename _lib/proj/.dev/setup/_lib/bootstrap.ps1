Set-StrictMode -Version 2.0

foreach ($File in @(
    'foundation.ps1',
    'state.ps1',
    'artifact.ps1',
    'install.ps1',
    'environment.ps1',
    'activation.ps1'
)) {
    . (Join-Path $PSScriptRoot $File)
}

$ModuleRoot = [IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\_modules')
)
foreach ($File in @(
    'bun\module.ps1',
    'bun\release.ps1',
    'bun\install.ps1'
)) {
    . (Join-Path $ModuleRoot $File)
}
