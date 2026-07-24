Set-StrictMode -Version 2.0

function New-XvenvExecEncodedCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Program,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    if ([string]::IsNullOrWhiteSpace($Program)) {
        throw 'Usage: xvenv exec <program> [args...]'
    }

    $ProgramBase64 = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($Program)
    )
    $WorkingDirectoryBase64 = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($WorkingDirectory)
    )
    $ArgumentLiterals = [Collections.Generic.List[string]]::new()
    foreach ($Argument in $Arguments) {
        $EncodedArgument = [Convert]::ToBase64String(
            [Text.Encoding]::UTF8.GetBytes([string]$Argument)
        )
        [void]$ArgumentLiterals.Add("'$EncodedArgument'")
    }
    $EncodedArguments = [string]::Join(', ', $ArgumentLiterals.ToArray())

    $ChildScript = @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
`$program = ''
try {
    `$program = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String('$ProgramBase64')
    )
    `$workingDirectory = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String('$WorkingDirectoryBase64')
    )
    Set-Location -LiteralPath `$workingDirectory
    `$arguments = [string[]]@(
        foreach (`$encoded in [string[]]@($EncodedArguments)) {
            [Text.Encoding]::UTF8.GetString(
                [Convert]::FromBase64String(`$encoded)
            )
        }
    )
    `$commandName = [Management.Automation.WildcardPattern]::Escape(`$program)
    `$commands = @(Get-Command -Name `$commandName -ErrorAction Stop)
    if (`$commands.Count -ne 1) {
        throw "Program name is ambiguous: `$program"
    }
    `$command = `$commands[0]
    `$isNative = `$command.CommandType -eq `
        [Management.Automation.CommandTypes]::Application
    `$isScript = `$command.CommandType -eq `
        [Management.Automation.CommandTypes]::ExternalScript
    `$global:LASTEXITCODE = `$null
    & `$command @arguments
    `$succeeded = `$?
    if (`$isNative -and `$null -ne `$global:LASTEXITCODE) {
        exit [int]`$global:LASTEXITCODE
    }
    if (-not `$succeeded) {
        if (`$isScript -and `$null -ne `$global:LASTEXITCODE) {
            exit [int]`$global:LASTEXITCODE
        }
        exit 1
    }
    exit 0
} catch {
    [Console]::Error.WriteLine(
        "[ERROR] xvenv exec failed for '`$program': `$(`$_.Exception.Message)"
    )
    exit 1
}
"@
    return [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($ChildScript)
    )
}

function Invoke-XvenvExec {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][string]$Program,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Arguments
    )

    Assert-XvenvNotActive
    $Plan = Import-XvenvGeneratedEnvironment -Context $Context
    Assert-XvenvPlanInstalled -Context $Context -Plan $Plan

    $PowerShell = Join-Path `
        $env:SystemRoot `
        'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not [IO.File]::Exists($PowerShell)) {
        throw "Windows PowerShell is required by xvenv exec: $PowerShell"
    }

    $CommandName = [Management.Automation.WildcardPattern]::Escape($Program)
    $Commands = @(Get-Command -Name $CommandName -ErrorAction Stop)
    if ($Commands.Count -ne 1) {
        throw "Program name is ambiguous: $Program"
    }
    $Command = $Commands[0]
    $Extension = [IO.Path]::GetExtension([string]$Command.Source).ToLowerInvariant()
    if ($Command.CommandType -eq [Management.Automation.CommandTypes]::Application -and
        $Extension -notin @('.cmd', '.bat')) {
        return Invoke-XvenvConsoleProcess `
            -Executable ([string]$Command.Source) `
            -Arguments $Arguments `
            -WorkingDirectory $Context.InvocationDirectory
    }

    $EncodedCommand = New-XvenvExecEncodedCommand `
        -Program $Program `
        -Arguments $Arguments `
        -WorkingDirectory $Context.InvocationDirectory
    if ($EncodedCommand.Length -gt 30000) {
        throw 'xvenv exec arguments exceed the Windows command-line limit. Put the complex command in a script file and execute that file instead.'
    }
    return Invoke-XvenvConsoleProcess `
        -Executable $PowerShell `
        -Arguments @(
            '-NoLogo',
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy',
            'Bypass',
            '-EncodedCommand',
            $EncodedCommand
        ) `
        -WorkingDirectory $Context.InvocationDirectory
}
