Set-StrictMode -Version 2.0

$Stage0ProjRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$Stage0ToolchainRoot = Join-Path $Stage0ProjRoot '_toolchain'
. (Join-Path $Stage0ToolchainRoot '_lib\runtime.ps1')

foreach ($File in @(
    'event.ps1',
    'artifact.ps1',
    'recovery.ps1',
    'install.ps1',
    'environment.ps1'
)) {
    . (Join-Path (Join-Path $Stage0ToolchainRoot '_lib') $File)
}

$Stage0ModuleRoot = Join-Path $Stage0ToolchainRoot '_modules'
foreach ($File in @(
    'bun\module.ps1',
    'bun\release.ps1',
    'bun\selection.ps1',
    'bun\install.ps1',
    'pwsh\module.ps1',
    'pwsh\release.ps1',
    'pwsh\selection.ps1',
    'pwsh\install.ps1',
    'msvc\module.ps1',
    'msvc\payload.ps1',
    'msvc\manifest.ps1',
    'msvc\release.ps1',
    'msvc\install.ps1',
    'msvc\environment.ps1',
    'rust\module.ps1',
    'rust\metadata.ps1',
    'rust\state.ps1',
    'rust\release.ps1',
    'rust\process.ps1',
    'rust\install.ps1',
    'rust\environment.ps1',
    'rust\command.ps1'
)) {
    . (Join-Path $Stage0ModuleRoot $File)
}
