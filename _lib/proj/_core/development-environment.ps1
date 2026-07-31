Set-StrictMode -Version 2.0

$script:ProjDevelopmentEnvironmentSchema =
    'swawkit.proj-dev.environment.v0'

function Test-ProjDevelopmentEnvironmentActive {
    $Environment = [Environment]::GetEnvironmentVariables(
        [EnvironmentVariableTarget]::Process
    )
    foreach ($Name in [string[]]@($Environment.Keys)) {
        if ($Name.StartsWith(
            'SWAWKIT_DEV_',
            [StringComparison]::OrdinalIgnoreCase
        )) {
            return $true
        }
    }
    return $false
}

function Assert-ProjActiveDevelopmentEnvironmentOwner {
    param([Parameter(Mandatory = $true)][object]$ProjectContext)

    if (-not (Test-ProjDevelopmentEnvironmentActive)) {
        return $false
    }

    foreach ($Name in @(
        'SWAWKIT_DEV_ENV_SCHEMA',
        'SWAWKIT_DEV_PROJECT_ID',
        'SWAWKIT_DEV_PROJECT_ROOT',
        'SWAWKIT_DEV_ENV_ROOT'
    )) {
        if ([string]::IsNullOrWhiteSpace(
            [Environment]::GetEnvironmentVariable($Name, 'Process')
        )) {
            throw (
                'An incomplete Swaw Kit development environment is already ' +
                'active. Start a clean shell before invoking this project.'
            )
        }
    }
    if ([string]$env:SWAWKIT_DEV_ENV_SCHEMA -cne
        $script:ProjDevelopmentEnvironmentSchema) {
        throw (
            'An unsupported Swaw Kit development environment is already ' +
            'active. Start a clean shell before invoking this project.'
        )
    }

    $ExpectedEnvironmentRoot = Get-ProjDeclaredFullPath `
        -Value (Join-Path $ProjectContext.DataRoot 'dev_env') `
        -Name 'development environment root'
    $ActiveProjectRoot = Get-ProjDeclaredFullPath `
        -Value ([string]$env:SWAWKIT_DEV_PROJECT_ROOT) `
        -Name 'SWAWKIT_DEV_PROJECT_ROOT'
    $ActiveEnvironmentRoot = Get-ProjDeclaredFullPath `
        -Value ([string]$env:SWAWKIT_DEV_ENV_ROOT) `
        -Name 'SWAWKIT_DEV_ENV_ROOT'
    if ([string]$env:SWAWKIT_DEV_PROJECT_ID -cne
            [string]$ProjectContext.ProjectId -or
        -not $ActiveProjectRoot.Equals(
            [string]$ProjectContext.ProjectRoot,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        -not $ActiveEnvironmentRoot.Equals(
            $ExpectedEnvironmentRoot,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw (
            "Another project's development environment is already active: " +
            "$([string]$env:SWAWKIT_DEV_PROJECT_ROOT). Start a clean shell " +
            'before invoking this project.'
        )
    }
    return $true
}

function Get-ProjDevelopmentEnvironmentGeneration {
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentRoot,
        [Parameter(Mandatory = $true)][string]$EntryCommand
    )

    $CmdPath = Join-Path $EnvironmentRoot 'env.cmd'
    $Ps1Path = Join-Path $EnvironmentRoot 'env.ps1'
    $HasCmd = [IO.File]::Exists($CmdPath)
    $HasPs1 = [IO.File]::Exists($Ps1Path)
    if (-not $HasCmd -and -not $HasPs1) {
        return $null
    }
    if (-not $HasCmd -or -not $HasPs1) {
        throw (
            'The published development environment is incomplete. Run ' +
            "'$EntryCommand .dev.setup'."
        )
    }

    $CmdMatch = [regex]::Match(
        [IO.File]::ReadAllText($CmdPath),
        '(?im)^set "SWAWKIT_DEV_GENERATION_ID=([a-f0-9]{16})"\s*$'
    )
    $Ps1Match = [regex]::Match(
        [IO.File]::ReadAllText($Ps1Path),
        "(?im)^\`$env:SWAWKIT_DEV_GENERATION_ID = '([a-f0-9]{16})'\s*$"
    )
    if (-not $CmdMatch.Success -or
        -not $Ps1Match.Success -or
        $CmdMatch.Groups[1].Value -cne $Ps1Match.Groups[1].Value) {
        throw (
            'The published development environment files do not match. Run ' +
            "'$EntryCommand .dev.setup'."
        )
    }
    return $CmdMatch.Groups[1].Value
}

function Assert-ProjDevelopmentEnvironmentIdentity {
    param(
        [Parameter(Mandatory = $true)][object]$ProjectContext,
        [Parameter(Mandatory = $true)][string]$GenerationId
    )

    if ([string]$env:SWAWKIT_DEV_GENERATION_ID -cne $GenerationId) {
        throw (
            'The active development environment generation is stale. Run ' +
            "'$($ProjectContext.EntryCommand) .dev.setup' outside the active " +
            'project shell, then start a new shell.'
        )
    }
    [void](Assert-ProjActiveDevelopmentEnvironmentOwner `
        -ProjectContext $ProjectContext)
}

function Import-ProjDevelopmentEnvironment {
    param([Parameter(Mandatory = $true)][object]$ProjectContext)

    $EnvironmentRoot = Get-ProjDeclaredFullPath `
        -Value (Join-Path $ProjectContext.DataRoot 'dev_env') `
        -Name 'development environment root'
    $AlreadyActive = Test-ProjDevelopmentEnvironmentActive
    $GenerationId = Get-ProjDevelopmentEnvironmentGeneration `
        -EnvironmentRoot $EnvironmentRoot `
        -EntryCommand $ProjectContext.EntryCommand

    if ($null -eq $GenerationId) {
        if ($AlreadyActive) {
            throw (
                'A managed development environment is active, but this ' +
                'project has no published environment. Start a clean shell.'
            )
        }
        return $false
    }

    if (-not $AlreadyActive) {
        . (Join-Path $EnvironmentRoot 'env.ps1')
    }
    Assert-ProjDevelopmentEnvironmentIdentity `
        -ProjectContext $ProjectContext `
        -GenerationId $GenerationId
    return $true
}
