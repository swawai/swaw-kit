Set-StrictMode -Version 2.0

foreach ($File in @(
    'argument-payload.ps1',
    'protocol.ps1',
    'process.ps1',
    'discovery.ps1',
    'entry-identity.ps1',
    'data-root-claim.ps1',
    'data-root.ps1',
    'project-context.ps1',
    'development-environment.ps1',
    'help.ps1',
    'runtime.ps1'
)) {
    . (Join-Path $PSScriptRoot $File)
}
