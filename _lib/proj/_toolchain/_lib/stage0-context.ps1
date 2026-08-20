Set-StrictMode -Version 2.0

function Get-ProjEnvironmentRepairInvocation {
    param([Parameter(Mandatory = $true)][object]$Context)

    $Property = $Context.PSObject.Properties['EnvironmentRepairInvocation']
    if ($null -eq $Property -or
        [string]::IsNullOrWhiteSpace([string]$Property.Value)) {
        throw 'The development environment repair invocation is missing.'
    }
    return [string]$Property.Value
}

function Get-ProjDevToolchainExecutable {
    param([Parameter(Mandatory = $true)][object]$Context)

    $Property = $Context.PSObject.Properties['ToolchainExecutable']
    if ($null -eq $Property -or [string]::IsNullOrWhiteSpace(
        [string]$Property.Value
    )) {
        return $null
    }
    $Path = Get-ProjDevFullPath -Path ([string]$Property.Value)
    $Item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $Item -or $Item.PSIsContainer -or
        ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The Proj Toolchain executable is unavailable: $Path"
    }
    return $Path
}

function Assert-ProjDevLoadedEnvironmentRevision {
    param(
        [Parameter(Mandatory = $true)][string]$Revision,
        [Parameter(Mandatory = $true)][string]$VariableName
    )

    $LoadedRevision = [Environment]::GetEnvironmentVariable(
        $VariableName,
        [EnvironmentVariableTarget]::Process
    )
    if ([string]$LoadedRevision -cne $Revision) {
        throw (
            'The loaded development environment does not match its published ' +
            'export revision.'
        )
    }
}
