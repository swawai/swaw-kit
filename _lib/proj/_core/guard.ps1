Set-StrictMode -Version 2.0

$script:ProjGuardAdapters = @(
    'exe',
    'powershell',
    'cmd'
)

function Resolve-ProjOptionalGuard {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$DirectoryName,
        [Parameter(Mandatory = $true)][ValidateSet('global', 'command')]
        [string]$Scope
    )

    $GuardDirectory = [IO.Path]::GetFullPath(
        (Join-Path $Root $DirectoryName)
    )
    Assert-ProjPathInsideRoot -Root $Root -Path $GuardDirectory
    if (-not [IO.Directory]::Exists($GuardDirectory)) {
        return $null
    }
    Assert-ProjNoReparsePoint `
        -Root $Root `
        -PhysicalSegments @($DirectoryName)

    $Resolution = Get-ProjEntryResolution -Directory $GuardDirectory
    if ($null -eq $Resolution.Selected) {
        if ($Resolution.Unsupported.Count -gt 0) {
            $Names = @($Resolution.Unsupported | ForEach-Object Name) -join ', '
            throw (
                "The $Scope guard exists, but this Core does not support " +
                "its entry: $Names"
            )
        }
        throw "The $Scope guard has no executable run.* entry: $GuardDirectory"
    }
    if ([string[]]$script:ProjGuardAdapters -cnotcontains
        [string]$Resolution.Selected.Adapter) {
        throw (
            "The $scope guard entry '$($Resolution.Selected.Name)' is not " +
            'bootstrap-safe. V0 guards support run.exe, run.ps1, or run.cmd.'
        )
    }
    return [pscustomobject][ordered]@{
        Scope = $Scope
        Directory = $GuardDirectory
        Entry = $Resolution.Selected
    }
}

function Get-ProjCommandGuards {
    param(
        [Parameter(Mandatory = $true)][string]$KernelRoot,
        [Parameter(Mandatory = $true)][object]$Command,
        [bool]$IncludeGlobal = $true
    )

    if ($IncludeGlobal) {
        $Global = Resolve-ProjOptionalGuard `
            -Root $KernelRoot `
            -DirectoryName '_global' `
            -Scope global
        if ($null -ne $Global) {
            $Global
        }
    }

    $Local = Resolve-ProjOptionalGuard `
        -Root ([string]$Command.Directory) `
        -DirectoryName '_guard' `
        -Scope command
    if ($null -ne $Local) {
        $Local
    }
}
