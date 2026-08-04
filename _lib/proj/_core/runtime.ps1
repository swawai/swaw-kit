Set-StrictMode -Version 2.0

function Get-ProjRuntimePath {
    param([Parameter(Mandatory = $true)][string]$Adapter)

    switch ($Adapter) {
        'powershell' {
            return [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
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
        [Parameter(Mandatory = $true)][string]$KernelRoot,
        [Parameter(Mandatory = $true)][string]$InvocationDirectory,
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Arguments = @(),
        [bool]$UseProjHelp = $false,
        [AllowEmptyString()][string]$HelpTargetAddress = '',
        [AllowNull()][object]$ProtocolCommand = $null,
        [AllowNull()][string]$RuntimeWorkingDirectory = $null,
        [ValidateSet('run', 'guard')][string]$ExecutionPhase = 'run',
        [ValidateSet('', 'global', 'command')][string]$GuardScope = ''
    )

    if ($null -eq $ProtocolCommand) {
        $ProtocolCommand = $Command
    }
    $ProjectRoot = [string]$ProjectContext.ProjectRoot
    $SavedEnvironment = @{}
    foreach ($Name in @(
        'SWAWKIT_PROJ_COMMAND_PROTOCOL',
        'SWAWKIT_PROJ_COMMAND_PHASE',
        'SWAWKIT_PROJ_COMMAND_ADDRESS',
        'SWAWKIT_PROJ_COMMAND_DIR',
        'SWAWKIT_PROJ_GUARD_SCOPE',
        'SWAWKIT_PROJ_INTERNAL_RUNTIME_WORKING_DIR',
        'SWAWKIT_PROJ_INVOCATION_DIR',
        'SWAWKIT_PROJ_HELP_TARGET_ADDRESS',
        'SWAWKIT_PROJ_PROTOCOL',
        'SWAWKIT_HOME',
        'SWAWKIT_PROJ_TARGET_PROJECT_ROOT',
        'SWAWKIT_PROJ_ACTION_ROOT',
        'SWAWKIT_PROJ_DATA_ROOT',
        'SWAWKIT_PROJ_ENTRY_COMMAND',
        'SWAWKIT_PROJ_ENTRY_FILE'
    )) {
        $SavedEnvironment[$Name] = [Environment]::GetEnvironmentVariable($Name, 'Process')
    }

    try {
        $env:SWAWKIT_PROJ_COMMAND_PROTOCOL = '1'
        $env:SWAWKIT_PROJ_COMMAND_PHASE = $ExecutionPhase
        $env:SWAWKIT_PROJ_COMMAND_ADDRESS = $ProtocolCommand.Address
        $env:SWAWKIT_PROJ_COMMAND_DIR = $ProtocolCommand.Directory
        if ($ExecutionPhase -ceq 'guard') {
            $env:SWAWKIT_PROJ_GUARD_SCOPE = $GuardScope
        } else {
            [Environment]::SetEnvironmentVariable(
                'SWAWKIT_PROJ_GUARD_SCOPE',
                $null,
                'Process'
            )
        }
        if ([string]::IsNullOrWhiteSpace($RuntimeWorkingDirectory)) {
            [Environment]::SetEnvironmentVariable(
                'SWAWKIT_PROJ_INTERNAL_RUNTIME_WORKING_DIR',
                $null,
                'Process'
            )
        } else {
            $env:SWAWKIT_PROJ_INTERNAL_RUNTIME_WORKING_DIR =
                [IO.Path]::GetFullPath($RuntimeWorkingDirectory)
        }
        $env:SWAWKIT_PROJ_INVOCATION_DIR = $InvocationDirectory
        if (-not $UseProjHelp) {
            [Environment]::SetEnvironmentVariable(
                'SWAWKIT_PROJ_HELP_TARGET_ADDRESS',
                $null,
                'Process'
            )
        } else {
            $env:SWAWKIT_PROJ_HELP_TARGET_ADDRESS = $HelpTargetAddress
        }
        $env:SWAWKIT_PROJ_PROTOCOL = $ProjectContext.Protocol
        $env:SWAWKIT_HOME = [string]$ProjectContext.ProjHome
        $env:SWAWKIT_PROJ_TARGET_PROJECT_ROOT = $ProjectContext.ProjectRoot
        $env:SWAWKIT_PROJ_ACTION_ROOT = $ProjectContext.ActionRoot
        $env:SWAWKIT_PROJ_DATA_ROOT = $ProjectContext.DataRoot
        $env:SWAWKIT_PROJ_ENTRY_COMMAND = $ProjectContext.EntryName
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
                $BunCommand = Resolve-ProjCommand `
                    -KernelRoot $KernelRoot `
                    -ActionRoot ([string]$ProjectContext.ActionRoot) `
                    -Address '.bun'
                if ([string]$BunCommand.Entry.Adapter -ceq 'bun') {
                    throw (
                        "The '.bun' runtime bridge cannot itself use run.ts."
                    )
                }
                [string[]]$BunArguments = @($Command.Entry.Path) + $Arguments
                $ExitCode = Invoke-ProjCommandPipeline `
                    -Command $BunCommand `
                    -ProjectContext $ProjectContext `
                    -KernelRoot $KernelRoot `
                    -InvocationDirectory $InvocationDirectory `
                    -Arguments $BunArguments `
                    -UseProjHelp $UseProjHelp `
                    -HelpTargetAddress $HelpTargetAddress `
                    -ProtocolCommand $ProtocolCommand `
                    -RuntimeWorkingDirectory $ProjectRoot `
                    -IncludeGlobal $false
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

function Invoke-ProjCommandGuards {
    param(
        [Parameter(Mandatory = $true)][object]$Command,
        [Parameter(Mandatory = $true)][object]$ProjectContext,
        [Parameter(Mandatory = $true)][string]$KernelRoot,
        [Parameter(Mandatory = $true)][string]$InvocationDirectory,
        [AllowNull()][object]$ProtocolCommand = $null,
        [bool]$UseProjHelp = $false,
        [AllowEmptyString()][string]$HelpTargetAddress = '',
        [bool]$IncludeGlobal = $true
    )

    if ($null -eq $ProtocolCommand) {
        $ProtocolCommand = $Command
    }
    foreach ($Guard in @(Get-ProjCommandGuards `
        -KernelRoot $KernelRoot `
        -Command $Command `
        -IncludeGlobal $IncludeGlobal)) {
        $ExitCode = Invoke-ProjResolvedCommand `
            -Command $Guard `
            -ProjectContext $ProjectContext `
            -KernelRoot $KernelRoot `
            -InvocationDirectory $InvocationDirectory `
            -ProtocolCommand $ProtocolCommand `
            -UseProjHelp $UseProjHelp `
            -HelpTargetAddress $HelpTargetAddress `
            -ExecutionPhase guard `
            -GuardScope ([string]$Guard.Scope)
        if ($ExitCode -ne 0) {
            return [int]$ExitCode
        }
    }
    return 0
}

function Invoke-ProjCommandPipeline {
    param(
        [Parameter(Mandatory = $true)][object]$Command,
        [Parameter(Mandatory = $true)][object]$ProjectContext,
        [Parameter(Mandatory = $true)][string]$KernelRoot,
        [Parameter(Mandatory = $true)][string]$InvocationDirectory,
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Arguments = @(),
        [bool]$UseProjHelp = $false,
        [AllowEmptyString()][string]$HelpTargetAddress = '',
        [AllowNull()][object]$ProtocolCommand = $null,
        [AllowNull()][string]$RuntimeWorkingDirectory = $null,
        [bool]$IncludeGlobal = $true
    )

    if ($null -eq $ProtocolCommand) {
        $ProtocolCommand = $Command
    }
    $GuardExitCode = Invoke-ProjCommandGuards `
        -Command $Command `
        -ProjectContext $ProjectContext `
        -KernelRoot $KernelRoot `
        -InvocationDirectory $InvocationDirectory `
        -ProtocolCommand $ProtocolCommand `
        -UseProjHelp $UseProjHelp `
        -HelpTargetAddress $HelpTargetAddress `
        -IncludeGlobal $IncludeGlobal
    if ($GuardExitCode -ne 0) {
        return [int]$GuardExitCode
    }
    return Invoke-ProjResolvedCommand `
        -Command $Command `
        -ProjectContext $ProjectContext `
        -KernelRoot $KernelRoot `
        -InvocationDirectory $InvocationDirectory `
        -Arguments $Arguments `
        -UseProjHelp $UseProjHelp `
        -HelpTargetAddress $HelpTargetAddress `
        -ProtocolCommand $ProtocolCommand `
        -RuntimeWorkingDirectory $RuntimeWorkingDirectory
}

function Resolve-ProjInvocation {
    param(
        [Parameter(Mandatory = $true)][string]$KernelRoot,
        [Parameter(Mandatory = $true)][string]$ActionRoot,
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Arguments = @()
    )

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
    return [pscustomobject][ordered]@{
        Command = $Command
        Arguments = $TailArguments
        UseProjHelp = $UseProjHelp
        HelpTargetAddress = $HelpTargetAddress
    }
}

function Invoke-ProjMain {
    param(
        [Parameter(Mandatory = $true)][string]$KernelRoot,
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Arguments = @()
    )

    $InvocationDirectory = (Get-Location).ProviderPath
    $ProjHome = [IO.Path]::GetFullPath((Join-Path $KernelRoot '..\..'))
    $ProjectContext = Get-ProjProjectContext -ProjHome $ProjHome
    $Invocation = Resolve-ProjInvocation `
        -KernelRoot $KernelRoot `
        -ActionRoot ([string]$ProjectContext.ActionRoot) `
        -Arguments $Arguments
    return Invoke-ProjCommandPipeline `
        -Command $Invocation.Command `
        -ProjectContext $ProjectContext `
        -KernelRoot $KernelRoot `
        -InvocationDirectory $InvocationDirectory `
        -Arguments $Invocation.Arguments `
        -UseProjHelp ([bool]$Invocation.UseProjHelp) `
        -HelpTargetAddress ([string]$Invocation.HelpTargetAddress)
}
