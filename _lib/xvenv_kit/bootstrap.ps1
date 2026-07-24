Set-StrictMode -Version 2.0

$SharedRoot = Join-Path $PSScriptRoot 'shared'
foreach ($File in @(
    'foundation.ps1',
    'module-loader.ps1',
    'definitions.ps1',
    'download.ps1',
    'install.ps1',
    'generated-environment.ps1',
    'process.ps1',
    'protocol.ps1'
)) {
    . (Join-Path $SharedRoot $File)
}

$CommandRoot = Join-Path $PSScriptRoot 'commands'
. (Join-Path $CommandRoot 'set-plan.ps1')
. (Join-Path $CommandRoot 'set.ps1')
. (Join-Path $CommandRoot 'status.ps1')
. (Join-Path $CommandRoot 'tools.ps1')
. (Join-Path $CommandRoot 'exec.ps1')
. (Join-Path $CommandRoot 'link.ps1')
. (Join-Path $CommandRoot 'help.ps1')
. (Join-Path $PSScriptRoot 'xvenv.ps1')
. (Join-Path $PSScriptRoot 'entry.ps1')
