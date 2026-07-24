Set-StrictMode -Version 2.0

function Invoke-XvenvOpenTerminal {
    param([Parameter(Mandatory = $true)][object]$Context)

    Assert-XvenvNotActive
    $Plan = Import-XvenvGeneratedEnvironment -Context $Context
    Assert-XvenvPlanInstalled -Context $Context -Plan $Plan

    $Kind = ([string]$env:XVENV_SHELL_KIND).ToLowerInvariant()
    $Executable = [string]$env:XVENV_SHELL_EXE
    $Arguments = [Collections.Generic.List[string]]::new()
    switch ($Kind) {
        'pwsh' {
            [void]$Arguments.Add('-NoExit')
            [void]$Arguments.Add('-NoLogo')
        }
        'cmd' {
            if ($Context.InvocationDirectory.StartsWith('\\', [StringComparison]::Ordinal)) {
                throw 'A project on a UNC path requires a configured shell that supports UNC working directories.'
            }
            [void]$Arguments.Add('/d')
            [void]$Arguments.Add('/v:off')
            [void]$Arguments.Add('/k')
        }
        default {
            throw "The generated xvenv shell is invalid: $Kind"
        }
    }
    if (-not [IO.File]::Exists($Executable)) {
        throw "The generated xvenv shell is missing: $Executable"
    }

    if ($null -ne $Context.LaunchTerminal) {
        return [int](& $Context.LaunchTerminal `
            $Executable `
            $Arguments.ToArray() `
            $Context.InvocationDirectory)
    }
    return Invoke-XvenvConsoleProcess `
        -Executable $Executable `
        -Arguments $Arguments.ToArray() `
        -WorkingDirectory $Context.InvocationDirectory
}
