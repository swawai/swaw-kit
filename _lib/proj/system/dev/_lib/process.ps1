Set-StrictMode -Version 2.0

$script:ProjDevTargetEnvironment = $null

function Get-ProjDevRepairInvocation {
    $EntryCommand = [string]$env:SWAWKIT_PROJ_ENTRY_COMMAND
    if ([string]::IsNullOrWhiteSpace($EntryCommand)) {
        return '.dev/setup'
    }
    return "$EntryCommand .dev/setup"
}

function Import-ProjDevTargetEnvironment {
    $script:ProjDevTargetEnvironment = $null
    $DataRoot = [string]$env:SWAWKIT_PROJ_DATA_ROOT
    $ExpectedInputRevision = [string]$env:SWAWKIT_PROJ_CORE_COMMAND_ENVIRONMENT_INPUT_REVISION
    if ([string]::IsNullOrWhiteSpace($DataRoot) -or
        [string]::IsNullOrWhiteSpace($ExpectedInputRevision)) {
        throw 'The current Entry development environment context is unavailable.'
    }
    $SetupRoot = Join-Path $DataRoot 'modules\system\dev\setup'
    $ExportRoot = Join-Path $SetupRoot 'export'
    $StatePath = Join-Path $SetupRoot '_state.json'
    $EnvironmentPath = Join-Path $ExportRoot 'environment.json'
    $ScriptPath = Join-Path $ExportRoot 'env.ps1'
    foreach ($Path in @($StatePath, $EnvironmentPath, $ScriptPath)) {
        $Item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        if ($null -eq $Item -or $Item.PSIsContainer -or
            $Item.Length -le 0 -or $Item.Length -gt 1MB -or
            ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw (
                "The current Entry development environment is unavailable. " +
                "Run '$(Get-ProjDevRepairInvocation)'."
            )
        }
    }
    try {
        $State = [IO.File]::ReadAllText(
            $StatePath,
            [Text.Encoding]::UTF8
        ) | ConvertFrom-Json
        $Environment = [IO.File]::ReadAllText(
            $EnvironmentPath,
            [Text.Encoding]::UTF8
        ) | ConvertFrom-Json
    } catch {
        throw (
            "The current Entry development environment is invalid. Run " +
            "'$(Get-ProjDevRepairInvocation)'."
        )
    }
    $Exports = @($State.exports)
    if ([string]$State.schema -cne 'swawkit.command-provider-state/v2' -or
        [string]$State.status -cne 'ready' -or
        [string]$State.inputRevision -cne $ExpectedInputRevision -or
        [string]$State.token -cnotmatch '^[a-f0-9]{32}$' -or
        $Exports.Count -ne 1 -or
        [string]$Exports[0].id -cne 'environment' -or
        [string]$Exports[0].contract -cne 'swawkit.proj.dev-setup/v3' -or
        [string]$Environment.schema -cne 'swawkit.proj-dev-environment/v1' -or
        [string]$Environment.inputRevision -cne $ExpectedInputRevision -or
        [string]$Environment.publicationToken -cne [string]$State.token) {
        throw (
            "The current Entry development environment is outdated. Run " +
            "'$(Get-ProjDevRepairInvocation)'."
        )
    }
    . $ScriptPath
    if ([string]$env:SWAWKIT_PROJ_MODULE_SYSTEM_DEV_SETUP_PUBLICATION_TOKEN -cne
        [string]$State.token) {
        throw 'The development environment script does not match its publication.'
    }
    $script:ProjDevTargetEnvironment = $Environment
}

function Resolve-ProjDevApplication {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Application,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )

    $PublishedProperty = switch ($Application.ToLowerInvariant()) {
        'bun.exe' { 'bunExecutable' }
        'pwsh.exe' { 'pwshExecutable' }
        default { $null }
    }
    if ($null -ne $PublishedProperty) {
        if ($null -eq $script:ProjDevTargetEnvironment) {
            throw 'The current Entry development environment was not imported.'
        }
        $PublishedPath = [string]$script:ProjDevTargetEnvironment.$PublishedProperty
        $Item = if ([string]::IsNullOrWhiteSpace($PublishedPath)) {
            $null
        } else {
            Get-Item -LiteralPath $PublishedPath -Force -ErrorAction SilentlyContinue
        }
        if ($null -eq $Item -or $Item.PSIsContainer -or
            [IO.Path]::GetFileName($PublishedPath) -ine $Application -or
            ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw (
                "$DisplayName is unavailable in the current Entry development " +
                "environment. Run '$(Get-ProjDevRepairInvocation)'."
            )
        }
        return $PublishedPath
    }

    $Command = if ([string]::IsNullOrWhiteSpace($Application)) {
        $null
    } else {
        Get-Command $Application `
            -CommandType Application `
            -ErrorAction SilentlyContinue |
            Select-Object -First 1
    }
    if ($null -eq $Command) {
        throw (
            "$DisplayName is unavailable in the current Entry development " +
            "environment. Run '$(Get-ProjDevRepairInvocation)'."
        )
    }
    return [string]$Command.Source
}
