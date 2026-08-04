Set-StrictMode -Version 2.0

$script:ProjDevelopmentEnvironmentSchema =
    'swawkit.proj-dev.environment.v0'
$script:ProjDevelopmentEnvironmentGenerationPlaceholder =
    '__SWAWKIT_PROJ_DEV_GENERATION_ID__'

function Get-ProjDevelopmentEnvironmentGenerationPlaceholder {
    return $script:ProjDevelopmentEnvironmentGenerationPlaceholder
}

function Assert-ProjDevelopmentEnvironmentControlledRoot {
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentRoot
    )

    $FullPath = [IO.Path]::GetFullPath($EnvironmentRoot)
    $Item = Get-Item `
        -LiteralPath $FullPath `
        -Force `
        -ErrorAction SilentlyContinue
    if ($null -eq $Item) {
        return $FullPath
    }
    if (($Item.Attributes -band
        [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw (
            'The managed development environment root cannot be a reparse ' +
            "point: $FullPath"
        )
    }
    if (-not $Item.PSIsContainer) {
        throw (
            'The managed development environment root must be a directory: ' +
            $FullPath
        )
    }
    return $FullPath
}

function Get-ProjDevelopmentEnvironmentContentGenerationId {
    param(
        [Parameter(Mandatory = $true)][string]$CmdContent,
        [Parameter(Mandatory = $true)][string]$Ps1Content
    )

    $Sha = [Security.Cryptography.SHA256]::Create()
    try {
        $Bytes = [Text.Encoding]::UTF8.GetBytes(
            "$CmdContent`n---`n$Ps1Content"
        )
        return ([BitConverter]::ToString(
            $Sha.ComputeHash($Bytes)
        ).Replace('-', '').ToLowerInvariant()).Substring(0, 16)
    } finally {
        $Sha.Dispose()
    }
}

function Restore-ProjDevelopmentEnvironmentGenerationPlaceholder {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][Text.RegularExpressions.Match]$Match
    )

    $GenerationGroup = $Match.Groups[1]
    return $Content.Substring(0, $GenerationGroup.Index) +
        (Get-ProjDevelopmentEnvironmentGenerationPlaceholder) +
        $Content.Substring($GenerationGroup.Index + $GenerationGroup.Length)
}

function Test-ProjDevelopmentEnvironmentActive {
    $Environment = [Environment]::GetEnvironmentVariables(
        [EnvironmentVariableTarget]::Process
    )
    foreach ($Name in [string[]]@($Environment.Keys)) {
        if ($Name.StartsWith(
            'SWAWKIT_PROJ_DEV_',
            [StringComparison]::OrdinalIgnoreCase
        ) -and -not [string]::IsNullOrEmpty([string]$Environment[$Name])) {
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
        'SWAWKIT_PROJ_DEV_ENV_SCHEMA',
        'SWAWKIT_PROJ_DEV_PROJECT_ROOT',
        'SWAWKIT_PROJ_DEV_ENV_ROOT'
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
    if ([string]$env:SWAWKIT_PROJ_DEV_ENV_SCHEMA -cne
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
        -Value ([string]$env:SWAWKIT_PROJ_DEV_PROJECT_ROOT) `
        -Name 'SWAWKIT_PROJ_DEV_PROJECT_ROOT'
    $ActiveEnvironmentRoot = Get-ProjDeclaredFullPath `
        -Value ([string]$env:SWAWKIT_PROJ_DEV_ENV_ROOT) `
        -Name 'SWAWKIT_PROJ_DEV_ENV_ROOT'
    if (-not $ActiveProjectRoot.Equals(
            [string]$ProjectContext.ProjectRoot,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        -not $ActiveEnvironmentRoot.Equals(
            $ExpectedEnvironmentRoot,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw (
            "Another project's development environment is already active: " +
            "$([string]$env:SWAWKIT_PROJ_DEV_PROJECT_ROOT). Start a clean shell " +
            'before invoking this project.'
        )
    }
    return $true
}

function Get-ProjPublishedDevelopmentEnvironmentGeneration {
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentRoot,
        [Parameter(Mandatory = $true)][string]$EntryCommand
    )

    $CmdPath = Join-Path $EnvironmentRoot 'env.cmd'
    $Ps1Path = Join-Path $EnvironmentRoot 'env.ps1'
    $StatePath = Get-ProjDevelopmentEnvironmentStatePath `
        -EnvironmentRoot $EnvironmentRoot
    $HasCmd = [IO.File]::Exists($CmdPath)
    $HasPs1 = [IO.File]::Exists($Ps1Path)
    $HasState = [IO.File]::Exists($StatePath)
    if (-not $HasCmd -and -not $HasPs1 -and -not $HasState) {
        return $null
    }
    if (-not $HasCmd -or -not $HasPs1 -or -not $HasState) {
        throw (
            'The published development environment is incomplete. Run ' +
            "'$EntryCommand .dev.setup'."
        )
    }

    $CmdContent = [IO.File]::ReadAllText($CmdPath)
    $Ps1Content = [IO.File]::ReadAllText($Ps1Path)
    $CmdMatches = [regex]::Matches(
        $CmdContent,
        '(?im)^set "SWAWKIT_PROJ_DEV_GENERATION_ID=([a-f0-9]{16})"\s*$'
    )
    $Ps1Matches = [regex]::Matches(
        $Ps1Content,
        "(?im)^\`$env:SWAWKIT_PROJ_DEV_GENERATION_ID = '([a-f0-9]{16})'\s*$"
    )
    if ($CmdMatches.Count -ne 1 -or $Ps1Matches.Count -ne 1) {
        throw (
            'The published development environment files do not contain ' +
            "one canonical generation ID. Run '$EntryCommand .dev.setup'."
        )
    }
    $CmdMatch = $CmdMatches[0]
    $Ps1Match = $Ps1Matches[0]
    if (
        $CmdMatch.Groups[1].Value -cne $Ps1Match.Groups[1].Value) {
        throw (
            'The published development environment files do not match. Run ' +
            "'$EntryCommand .dev.setup'."
        )
    }
    $GenerationId = $CmdMatch.Groups[1].Value
    $UnversionedCmd = Restore-ProjDevelopmentEnvironmentGenerationPlaceholder `
        -Content $CmdContent `
        -Match $CmdMatch
    $UnversionedPs1 = Restore-ProjDevelopmentEnvironmentGenerationPlaceholder `
        -Content $Ps1Content `
        -Match $Ps1Match
    $ContentGenerationId =
        Get-ProjDevelopmentEnvironmentContentGenerationId `
            -CmdContent $UnversionedCmd `
            -Ps1Content $UnversionedPs1
    if ($ContentGenerationId -cne $GenerationId) {
        throw (
            'The published development environment files were modified or ' +
            "damaged. Run '$EntryCommand .dev.setup'."
        )
    }
    $State = Read-ProjDevelopmentEnvironmentState `
        -EnvironmentRoot $EnvironmentRoot
    if ([string]$State.GenerationId -cne $GenerationId) {
        throw (
            'The published development environment state does not match ' +
            "env.cmd and env.ps1. Run '$EntryCommand .dev.setup'."
        )
    }

    return $GenerationId
}

function Get-ProjDevelopmentEnvironmentGeneration {
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentRoot,
        [Parameter(Mandatory = $true)][string]$EntryCommand
    )

    $GenerationId = Get-ProjPublishedDevelopmentEnvironmentGeneration `
        -EnvironmentRoot $EnvironmentRoot `
        -EntryCommand $EntryCommand
    if ($null -eq $GenerationId) {
        return $null
    }
    $State = Read-ProjDevelopmentEnvironmentState `
        -EnvironmentRoot $EnvironmentRoot
    $Declared = Get-ProjDevelopmentDeclarationSnapshot
    $Differences = @(Compare-ProjDevelopmentDeclarations `
        -Applied $State.Declarations `
        -Declared $Declared)
    if ($Differences.Count -gt 0) {
        $Lines = [Collections.Generic.List[string]]::new()
        [void]$Lines.Add(
            '[DEV ENV OUTDATED] The project development declarations changed.'
        )
        foreach ($Difference in $Differences) {
            [void]$Lines.Add(
                "  $($Difference.Name): '$($Difference.Applied)' -> " +
                "'$($Difference.Declared)'"
            )
        }
        [void]$Lines.Add("Run '$EntryCommand .dev.setup'.")
        throw [string]::Join([Environment]::NewLine, $Lines)
    }
    return $GenerationId
}

function Assert-ProjDevelopmentEnvironmentIdentity {
    param(
        [Parameter(Mandatory = $true)][object]$ProjectContext,
        [Parameter(Mandatory = $true)][string]$GenerationId
    )

    if ([string]$env:SWAWKIT_PROJ_DEV_GENERATION_ID -cne $GenerationId) {
        throw (
            'The active development environment generation no longer matches ' +
            'the published environment. Start a clean project shell before ' +
            'continuing.'
        )
    }
    [void](Assert-ProjActiveDevelopmentEnvironmentOwner `
        -ProjectContext $ProjectContext)
}

function Assert-ProjActiveDevelopmentEnvironmentPublishedGeneration {
    param([Parameter(Mandatory = $true)][object]$ProjectContext)

    if (-not (Assert-ProjActiveDevelopmentEnvironmentOwner `
        -ProjectContext $ProjectContext)) {
        return $false
    }
    $EnvironmentRoot = Get-ProjDeclaredFullPath `
        -Value (Join-Path $ProjectContext.DataRoot 'dev_env') `
        -Name 'development environment root'
    $GenerationId = Get-ProjPublishedDevelopmentEnvironmentGeneration `
        -EnvironmentRoot $EnvironmentRoot `
        -EntryCommand $ProjectContext.EntryName
    if ($null -eq $GenerationId) {
        throw (
            'A project development environment is active, but no environment ' +
            'is published. Start a clean shell and run ' +
            "'$($ProjectContext.EntryName) .dev.setup'."
        )
    }
    Assert-ProjDevelopmentEnvironmentIdentity `
        -ProjectContext $ProjectContext `
        -GenerationId $GenerationId
    return $true
}

function Import-ProjDevelopmentEnvironment {
    param([Parameter(Mandatory = $true)][object]$ProjectContext)

    $EnvironmentRoot = Get-ProjDeclaredFullPath `
        -Value (Join-Path $ProjectContext.DataRoot 'dev_env') `
        -Name 'development environment root'
    $AlreadyActive = Test-ProjDevelopmentEnvironmentActive
    $GenerationId = Get-ProjDevelopmentEnvironmentGeneration `
        -EnvironmentRoot $EnvironmentRoot `
        -EntryCommand $ProjectContext.EntryName

    if ($null -eq $GenerationId) {
        if ($AlreadyActive) {
            throw (
                'A managed development environment is active, but this ' +
                'project has no published environment. Start a clean shell.'
            )
        }
        $EnabledDeclarations = @(
            Get-ProjEnabledDevelopmentDeclarationNames `
                -Declarations (Get-ProjDevelopmentDeclarationSnapshot)
        )
        if ($EnabledDeclarations.Count -gt 0) {
            throw (
                'The project declares managed development tools, but no ' +
                'environment has been published. Enabled: ' +
                [string]::Join(', ', $EnabledDeclarations) + '. Run ' +
                "'$($ProjectContext.EntryName) .dev.setup'."
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
