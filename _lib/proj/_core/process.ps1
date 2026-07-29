Set-StrictMode -Version 2.0

function ConvertTo-ProjWindowsArgument {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') {
        return $Value
    }

    $Builder = [Text.StringBuilder]::new()
    [void]$Builder.Append('"')
    $Backslashes = 0
    foreach ($Character in $Value.ToCharArray()) {
        if ($Character -eq [char]'\') {
            $Backslashes++
            continue
        }
        if ($Character -eq [char]'"') {
            [void]$Builder.Append([char]'\', $Backslashes * 2 + 1)
            [void]$Builder.Append('"')
            $Backslashes = 0
            continue
        }
        if ($Backslashes -gt 0) {
            [void]$Builder.Append([char]'\', $Backslashes)
            $Backslashes = 0
        }
        [void]$Builder.Append($Character)
    }
    if ($Backslashes -gt 0) {
        [void]$Builder.Append([char]'\', $Backslashes * 2)
    }
    [void]$Builder.Append('"')
    return $Builder.ToString()
}

function ConvertTo-ProjWindowsArguments {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Arguments
    )

    $Encoded = foreach ($Argument in $Arguments) {
        ConvertTo-ProjWindowsArgument -Value ([string]$Argument)
    }
    return [string]::Join(' ', [string[]]@($Encoded))
}

function Invoke-ProjConsoleProcess {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    if (-not (Test-ProjWindows)) {
        throw 'The V0 native process adapter currently supports Windows only.'
    }

    $StartInfo = [Diagnostics.ProcessStartInfo]::new()
    $StartInfo.FileName = $Executable
    $StartInfo.Arguments = ConvertTo-ProjWindowsArguments -Arguments $Arguments
    if ($StartInfo.Arguments.Length -gt 32000) {
        throw 'The child process arguments exceed the Windows command-line limit.'
    }
    $StartInfo.WorkingDirectory = $WorkingDirectory
    $StartInfo.UseShellExecute = $false
    $StartInfo.CreateNoWindow = $false

    $Process = [Diagnostics.Process]::Start($StartInfo)
    if ($null -eq $Process) {
        throw "Failed to start the console process: $Executable"
    }
    try {
        $Process.WaitForExit()
        return [int]$Process.ExitCode
    } finally {
        $Process.Dispose()
    }
}

function Invoke-ProjCmdProcess {
    param(
        [Parameter(Mandatory = $true)][string]$EntryPath,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [AllowEmptyString()][string]$HelpMarker = ''
    )

    if (-not (Test-ProjWindows)) {
        throw 'The V0 CMD adapter supports Windows only.'
    }
    if ([string]::IsNullOrWhiteSpace($env:ComSpec) -or
        -not [IO.File]::Exists($env:ComSpec)) {
        throw 'The Windows command processor is not available.'
    }

    if (
        -not [string]::IsNullOrEmpty($HelpMarker) -and
        -not (Test-ProjHelpMarker -Value $HelpMarker)
    ) {
        throw "Unsafe CMD help selector '$HelpMarker'."
    }

    $StartInfo = [Diagnostics.ProcessStartInfo]::new()
    $StartInfo.FileName = $env:ComSpec
    $StartInfo.Arguments = if ([string]::IsNullOrEmpty($HelpMarker)) {
        '/d /s /v:off /c ""%SWAWKIT_INTERNAL_CMD_ENTRY_PATH%""'
    } else {
        '/d /s /v:off /c ""%SWAWKIT_INTERNAL_CMD_ENTRY_PATH%" ' +
            $HelpMarker +
            '"'
    }
    $StartInfo.WorkingDirectory = $WorkingDirectory
    $StartInfo.UseShellExecute = $false
    $StartInfo.CreateNoWindow = $false

    $VariableName = 'SWAWKIT_INTERNAL_CMD_ENTRY_PATH'
    $PreviousEntryPath = [Environment]::GetEnvironmentVariable(
        $VariableName,
        'Process'
    )
    try {
        [Environment]::SetEnvironmentVariable(
            $VariableName,
            $EntryPath,
            'Process'
        )
        $Process = [Diagnostics.Process]::Start($StartInfo)
        if ($null -eq $Process) {
            throw "Failed to start the CMD entry: $EntryPath"
        }
        try {
            $Process.WaitForExit()
            return [int]$Process.ExitCode
        } finally {
            $Process.Dispose()
        }
    } finally {
        [Environment]::SetEnvironmentVariable(
            $VariableName,
            $PreviousEntryPath,
            'Process'
        )
    }
}
