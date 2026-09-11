Set-StrictMode -Version 2.0

foreach ($File in @(
    'revision.ps1',
    'foundation.ps1',
    'controlled-path.ps1',
    'stage0-context.ps1',
    'state.ps1'
)) {
    . (Join-Path $PSScriptRoot $File)
}
