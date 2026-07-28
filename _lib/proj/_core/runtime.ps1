Set-StrictMode -Version 2.0

function Get-ProjRuntimePath {
    param([Parameter(Mandatory = $true)][string]$Adapter)

    switch ($Adapter) {
        'powershell' {
            return [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        }
        'bun' {
            $Command = Get-Command bun -CommandType Application -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($null -eq $Command) {
                throw "The Bun runtime is not ready for the selected run.ts entry."
            }
            return $Command.Source
        }
        'python' {
            $Command = Get-Command python -CommandType Application -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($null -eq $Command) {
                throw "The Python runtime is not ready for the selected run.py entry."
            }
            return $Command.Source
        }
        default { return $null }
    }
}

function Invoke-ProjResolvedCommand {
    param(
        [Parameter(Mandatory = $true)][object]$Command,
        [Parameter(Mandatory = $true)][object]$ProjectContext,
        [Parameter(Mandatory = $true)][string]$InvocationDirectory,
        [AllowEmptyCollection()][string[]]$Arguments = @(),
        [bool]$UseProjHelp = $false,
        [AllowEmptyString()][string]$HelpTargetAddress = ''
    )

    $ProjectRoot = [string]$ProjectContext.ProjectRoot
    $SavedEnvironment = @{}
    foreach ($Name in @(
        'SWAWKIT_COMMAND_PROTOCOL',
        'SWAWKIT_COMMAND_ADDRESS',
        'SWAWKIT_COMMAND_DIR',
        'SWAWKIT_INVOCATION_DIR',
        'SWAWKIT_HELP_TARGET_ADDRESS',
        'SWAWKIT_PROJ_PROTOCOL',
        'SWAWKIT_PROJ_ID',
        'SWAWKIT_PROJ_DIR',
        'SWAWKIT_PROJ_ACTION_ROOT',
        'SWAWKIT_PROJ_DATA_ROOT',
        'SWAWKIT_PROJ_ENTRY_COMMAND',
        'SWAWKIT_PROJ_ENTRY_FILE'
    )) {
        $SavedEnvironment[$Name] = [Environment]::GetEnvironmentVariable($Name, 'Process')
    }

    try {
        $env:SWAWKIT_COMMAND_PROTOCOL = '1'
        $env:SWAWKIT_COMMAND_ADDRESS = $Command.Address
        $env:SWAWKIT_COMMAND_DIR = $Command.Directory
        $env:SWAWKIT_INVOCATION_DIR = $InvocationDirectory
        if (-not $UseProjHelp) {
            [Environment]::SetEnvironmentVariable(
                'SWAWKIT_HELP_TARGET_ADDRESS',
                $null,
                'Process'
            )
        } else {
            $env:SWAWKIT_HELP_TARGET_ADDRESS = $HelpTargetAddress
        }
        $env:SWAWKIT_PROJ_PROTOCOL = $ProjectContext.Protocol
        $env:SWAWKIT_PROJ_ID = $ProjectContext.ProjectId
        $env:SWAWKIT_PROJ_DIR = $ProjectContext.ProjectRoot
        $env:SWAWKIT_PROJ_ACTION_ROOT = $ProjectContext.ActionRoot
        $env:SWAWKIT_PROJ_DATA_ROOT = $ProjectContext.DataRoot
        $env:SWAWKIT_PROJ_ENTRY_COMMAND = $ProjectContext.EntryCommand
        $env:SWAWKIT_PROJ_ENTRY_FILE = $ProjectContext.EntryFile

        switch ($Command.Entry.Adapter) {
            'exe' {
                $ExitCode = Invoke-ProjConsoleProcess `
                    -Executable $Command.Entry.Path `
                    -Arguments $Arguments `
                    -WorkingDirectory $ProjectRoot
            }
            'cmd' {
                [string]$CmdHelpMarker = ''
                if ($null -ne $Arguments -and $Arguments.Length -gt 0) {
                    if (
                        $Arguments.Length -ne 1 -or
                        -not (Test-ProjHelpMarker -Value $Arguments[0])
                    ) {
                        throw (
                            'The V0 run.cmd adapter does not accept dynamic ' +
                            'tail arguments other than one standalone help selector.'
                        )
                    }
                    $CmdHelpMarker = $Arguments[0]
                }
                $ExitCode = Invoke-ProjCmdProcess `
                    -EntryPath $Command.Entry.Path `
                    -WorkingDirectory $ProjectRoot `
                    -HelpMarker $CmdHelpMarker
            }
            'powershell' {
                $Runtime = Get-ProjRuntimePath -Adapter powershell
                $Runner = Join-Path $PSScriptRoot 'powershell-runner.ps1'
                $ArgumentPayload = ConvertTo-ProjArgumentPayload -Arguments $Arguments
                [string[]]$RunnerArguments = @(
                    '-NoLogo',
                    '-NoProfile',
                    '-ExecutionPolicy',
                    'Bypass',
                    '-File',
                    $Runner,
                    '-EntryPath',
                    $Command.Entry.Path,
                    '-ArgumentPayload',
                    $ArgumentPayload
                )
                $ExitCode = Invoke-ProjConsoleProcess `
                    -Executable $Runtime `
                    -Arguments $RunnerArguments `
                    -WorkingDirectory $ProjectRoot
            }
            'bun' {
                $Runtime = Get-ProjRuntimePath -Adapter bun
                [string[]]$RuntimeArguments = @($Command.Entry.Path) + $Arguments
                $ExitCode = Invoke-ProjConsoleProcess `
                    -Executable $Runtime `
                    -Arguments $RuntimeArguments `
                    -WorkingDirectory $ProjectRoot
            }
            'python' {
                $Runtime = Get-ProjRuntimePath -Adapter python
                [string[]]$RuntimeArguments = @($Command.Entry.Path) + $Arguments
                $ExitCode = Invoke-ProjConsoleProcess `
                    -Executable $Runtime `
                    -Arguments $RuntimeArguments `
                    -WorkingDirectory $ProjectRoot
            }
            default {
                throw "Unsupported selected adapter '$($Command.Entry.Adapter)'."
            }
        }
        return [int]$ExitCode
    } finally {
        foreach ($Name in $SavedEnvironment.Keys) {
            $Previous = $SavedEnvironment[$Name]
            if ($null -eq $Previous) {
                [Environment]::SetEnvironmentVariable($Name, $null, 'Process')
            } else {
                [Environment]::SetEnvironmentVariable($Name, [string]$Previous, 'Process')
            }
        }
    }
}

function Invoke-ProjMain {
    param(
        [Parameter(Mandatory = $true)][string]$KernelRoot,
        [AllowEmptyCollection()][string[]]$Arguments = @()
    )

    $InvocationDirectory = (Get-Location).ProviderPath
    $ProjectContext = Get-ProjProjectContext
    $ProjectRoot = $ProjectContext.ProjectRoot
    $ActionRoot = $ProjectContext.ActionRoot

    $Address = if ($Arguments.Count -eq 0) { '' } else { $Arguments[0] }
    [string[]]$RawTailArguments = @()
    if ($Arguments.Count -gt 1) {
        $RawTailArguments = @($Arguments[1..($Arguments.Count - 1)])
    }

    $UseProjHelp = $false
    [string]$HelpTargetAddress = ''
    if (
        $RawTailArguments.Count -eq 1 -and
        (Test-ProjHelpMarker -Value $RawTailArguments[0]) -and
        (Test-ProjUsesLocalHelp `
            -KernelRoot $KernelRoot `
            -ActionRoot $ActionRoot `
            -TargetAddress $Address)
    ) {
        $UseProjHelp = $true
        $HelpTargetAddress = $Address
        $Address = '.help'
        [string[]]$TailArguments = @()
    } else {
        [string[]]$TailArguments = $RawTailArguments
    }

    $Command = Resolve-ProjCommand `
        -KernelRoot $KernelRoot `
        -ActionRoot $ActionRoot `
        -Address $Address
    return Invoke-ProjResolvedCommand `
        -Command $Command `
        -ProjectContext $ProjectContext `
        -InvocationDirectory $InvocationDirectory `
        -Arguments $TailArguments `
        -UseProjHelp $UseProjHelp `
        -HelpTargetAddress $HelpTargetAddress
}
