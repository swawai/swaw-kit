Set-StrictMode -Version 2.0

$script:SshAccessKitRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

foreach ($RelativePath in @(
    'runtime\process-environment.ps1',
    'runtime\console.ps1',
    'runtime\context.ps1',
    'runtime\process.ps1',
    'runtime\elevation.ps1',
    'help.ps1',
    'domains\key\public-key.ps1',
    'domains\key\state.ps1',
    'domains\key\commands.ps1',
    'domains\private\agent.ps1',
    'domains\private\commands.ps1',
    'domains\public\account.ps1',
    'domains\public\sshd-config.ps1',
    'domains\public\acl.ps1',
    'domains\public\authorized-key-references.ps1',
    'domains\public\authorized-keys.ps1',
    'domains\public\commands.ps1',
    'domains\global\client.ps1',
    'domains\global\server-config-io.ps1',
    'domains\global\server-config.ps1',
    'domains\global\firewall.ps1',
    'domains\global\shell.ps1',
    'domains\global\server.ps1',
    'domains\global\server-port.ps1',
    'domains\global\commands.ps1',
    'domains\status\command.ps1',
    'runtime\dispatch.ps1'
)) {
    . (Join-Path $script:SshAccessKitRoot $RelativePath)
}
