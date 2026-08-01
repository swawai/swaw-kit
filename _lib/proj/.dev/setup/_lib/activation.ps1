Set-StrictMode -Version 2.0

function Get-ProjDevGeneratedEnvironmentGeneration {
    param([Parameter(Mandatory = $true)][object]$Context)

    $HasCmd = [IO.File]::Exists($Context.EnvCmdPath)
    $HasPs1 = [IO.File]::Exists($Context.EnvPs1Path)
    if (-not $HasCmd -and -not $HasPs1) {
        throw (
            'The project development environment is not configured. Run ' +
            "'$($Context.EntryCommand) .dev.setup'."
        )
    }
    if (-not $HasCmd -or -not $HasPs1) {
        throw (
            'The generated project environment is incomplete. Run ' +
            "'$($Context.EntryCommand) .dev.setup'."
        )
    }

    $CmdContent = [IO.File]::ReadAllText($Context.EnvCmdPath)
    $CmdMatch = [regex]::Match(
        $CmdContent,
        '(?im)^set "SWAWKIT_DEV_GENERATION_ID=([a-f0-9]{16})"\s*$'
    )
    $Ps1Content = [IO.File]::ReadAllText($Context.EnvPs1Path)
    $Ps1Match = [regex]::Match(
        $Ps1Content,
        "(?im)^\`$env:SWAWKIT_DEV_GENERATION_ID = '([a-f0-9]{16})'\s*$"
    )
    if (-not $CmdMatch.Success -or
        -not $Ps1Match.Success -or
        $CmdMatch.Groups[1].Value -cne $Ps1Match.Groups[1].Value) {
        throw (
            'The generated environment files do not match. Run ' +
            "'$($Context.EntryCommand) .dev.setup'."
        )
    }
    return $CmdMatch.Groups[1].Value
}

function Clear-ProjDevProcessEnvironmentVariables {
    $ProcessEnvironment = [Environment]::GetEnvironmentVariables(
        [EnvironmentVariableTarget]::Process
    )
    foreach ($Name in [string[]]@($ProcessEnvironment.Keys)) {
        if ($Name.StartsWith(
            'SWAWKIT_DEV_',
            [StringComparison]::OrdinalIgnoreCase
        )) {
            [Environment]::SetEnvironmentVariable($Name, $null, 'Process')
        }
    }
}

function Assert-ProjDevActivatedEnvironmentIdentity {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][string]$GenerationId
    )

    if ([string]$env:SWAWKIT_DEV_GENERATION_ID -cne $GenerationId) {
        throw (
            'The active development environment generation is stale. ' +
            'Exit this shell and start a new project shell.'
        )
    }
    if ([string]$env:SWAWKIT_DEV_ENV_SCHEMA -cne
        'swawkit.proj-dev.environment.v0') {
        throw "Unsupported generated environment schema. Run '.dev.setup'."
    }
    foreach ($Name in @(
        'SWAWKIT_DEV_PROJECT_ROOT',
        'SWAWKIT_DEV_ENV_ROOT'
    )) {
        if ([string]::IsNullOrWhiteSpace(
            [Environment]::GetEnvironmentVariable($Name, 'Process')
        )) {
            throw "Generated environment is missing $Name. Run '.dev.setup'."
        }
    }
    if (-not (Get-ProjDevCanonicalPath -Path (
            [string]$env:SWAWKIT_DEV_PROJECT_ROOT
        )).Equals(
            $Context.CanonicalProjectRoot,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        -not (Get-ProjDevCanonicalPath -Path (
            [string]$env:SWAWKIT_DEV_ENV_ROOT
        )).Equals(
            (Get-ProjDevCanonicalPath -Path $Context.EnvironmentRoot),
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'The generated environment belongs to another project or data root.'
    }
}

function Import-ProjDevGeneratedEnvironment {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [bool]$AlreadyActive = $false
    )

    $GenerationId = Get-ProjDevGeneratedEnvironmentGeneration `
        -Context $Context
    if (-not $AlreadyActive) {
        Clear-ProjDevProcessEnvironmentVariables
        . $Context.EnvPs1Path
    }
    Assert-ProjDevActivatedEnvironmentIdentity `
        -Context $Context `
        -GenerationId $GenerationId

    return [pscustomobject][ordered]@{
        GenerationId = $GenerationId
        ProjectRoot = [string]$env:SWAWKIT_DEV_PROJECT_ROOT
        EnvironmentRoot = [string]$env:SWAWKIT_DEV_ENV_ROOT
    }
}
