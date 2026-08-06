Set-StrictMode -Version 2.0

function Invoke-ProjBootstrapEnvironmentIsolated {
    param([Parameter(Mandatory = $true)][scriptblock]$Action)

    $Snapshot = [Collections.Generic.Dictionary[string, string]]::new(
        [StringComparer]::Ordinal
    )
    $Before = [Environment]::GetEnvironmentVariables(
        [EnvironmentVariableTarget]::Process
    )
    foreach ($Name in [string[]]@($Before.Keys)) {
        $Snapshot[$Name] = [string]$Before[$Name]
    }

    try {
        & $Action
    } finally {
        $After = [Environment]::GetEnvironmentVariables(
            [EnvironmentVariableTarget]::Process
        )
        foreach ($Name in [string[]]@($After.Keys)) {
            if (-not $Snapshot.ContainsKey($Name)) {
                [Environment]::SetEnvironmentVariable(
                    $Name,
                    $null,
                    [EnvironmentVariableTarget]::Process
                )
            }
        }
        $Restored = [Environment]::GetEnvironmentVariables(
            [EnvironmentVariableTarget]::Process
        )
        foreach ($Pair in $Snapshot.GetEnumerator()) {
            $Name = [string]$Pair.Key
            $Value = [string]$Pair.Value
            if ($Restored.Contains($Name) -and
                [string]$Restored[$Name] -ceq $Value) {
                continue
            }
            [Environment]::SetEnvironmentVariable(
                $Name,
                $Value,
                [EnvironmentVariableTarget]::Process
            )
        }
    }
}

function Initialize-ProjBootstrapCore {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimePath,
        [Parameter(Mandatory = $true)][string]$BootstrapPath
    )

    $Runtime = [IO.Path]::GetFullPath($RuntimePath)
    if ([IO.File]::Exists($Runtime)) {
        return
    }
    $Bootstrap = [IO.Path]::GetFullPath($BootstrapPath)
    if (-not [IO.File]::Exists($Bootstrap)) {
        throw "The Proj Core Bootstrap is missing: $Bootstrap"
    }

    $global:LASTEXITCODE = 0
    & $Bootstrap
    $BootstrapExitCode = $LASTEXITCODE
    if ($BootstrapExitCode -ne 0) {
        throw "Proj Core Bootstrap failed with exit code $BootstrapExitCode."
    }
    if (-not [IO.File]::Exists($Runtime)) {
        throw "Proj Core Bootstrap did not publish its runtime: $Runtime"
    }
}

function Assert-ProjBootstrapPhysicalDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $FullPath = [IO.Path]::GetFullPath($Path)
    $Item = Get-Item -LiteralPath $FullPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $Item -or
        -not $Item.PSIsContainer -or
        ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Description is unsafe: $FullPath"
    }
    return $Item
}

function Get-ProjBootstrapLauncherFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description,
        [switch]$AllowMissing
    )

    $FullPath = [IO.Path]::GetFullPath($Path)
    $Item = Get-Item -LiteralPath $FullPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $Item) {
        if ($AllowMissing) {
            return $null
        }
        throw "$Description is missing: $FullPath"
    }
    if ($Item.PSIsContainer -or
        ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Description is not a physical file: $FullPath"
    }
    if ($Item.Length -le 0 -or $Item.Length -gt 64KB) {
        throw (
            "$Description has an invalid size $($Item.Length) bytes: " +
            $FullPath
        )
    }
    return $Item
}

function Publish-ProjBootstrapRootEntry {
    param(
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [Parameter(Mandatory = $true)][string]$EntryPath
    )

    $Template = Get-ProjBootstrapLauncherFile `
        -Path $TemplatePath `
        -Description 'The Proj Launcher template'
    $Destination = [IO.Path]::GetFullPath($EntryPath)
    if ($Template.FullName.Equals(
        $Destination,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'The Launcher template and root Entry paths must be different.'
    }

    $Existing = Get-ProjBootstrapLauncherFile `
        -Path $Destination `
        -Description 'The root Proj Entry' `
        -AllowMissing
    if ($null -ne $Existing) {
        return $Existing
    }

    $DestinationParent = Split-Path -Path $Destination -Parent
    [void](Assert-ProjBootstrapPhysicalDirectory `
        -Path $DestinationParent `
        -Description 'The root Entry directory')

    $StagedPath = Join-Path $DestinationParent (
        ".$([IO.Path]::GetFileName($Destination))." +
        "$([Guid]::NewGuid().ToString('N')).tmp"
    )
    try {
        [IO.File]::Copy($Template.FullName, $StagedPath, $false)
        [void](Get-ProjBootstrapLauncherFile `
            -Path $StagedPath `
            -Description 'The staged root Proj Entry')
        [IO.File]::Move($StagedPath, $Destination)
    } finally {
        if ([IO.File]::Exists($StagedPath)) {
            [IO.File]::Delete($StagedPath)
        }
    }

    $Published = Get-ProjBootstrapLauncherFile `
        -Path $Destination `
        -Description 'The published root Proj Entry'
    Write-Host "[PUBLISHED] $($Published.FullName)" -ForegroundColor Green
    return $Published
}

function Resolve-ProjBootstrapMsvcExecutable {
    param([Parameter(Mandatory = $true)][string]$Name)

    $ManagedRootValue = [string]$env:SWAWKIT_PROJ_DEV_MSVC_HOME
    if ([string]$env:SWAWKIT_PROJ_DEV_ENV_SCHEMA -cne
            'swawkit.proj-dev.environment.v0' -or
        [string]$env:SWAWKIT_PROJ_DEV_MSVC_MODE -cne 'managed' -or
        [string]::IsNullOrWhiteSpace($ManagedRootValue) -or
        [string]::IsNullOrWhiteSpace(
            [string]$env:SWAWKIT_PROJ_DEV_MSVC_SIGNATURE
        )) {
        throw 'The Bootstrap managed MSVC environment is incomplete.'
    }

    $Command = Get-Command $Name `
        -CommandType Application `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $Command) {
        throw "The Bootstrap managed MSVC environment does not expose $Name."
    }

    $ManagedRoot = [IO.Path]::GetFullPath($ManagedRootValue).TrimEnd(
        '\', '/'
    ) + [IO.Path]::DirectorySeparatorChar
    $ExecutablePath = [IO.Path]::GetFullPath([string]$Command.Source)
    if (-not $ExecutablePath.StartsWith(
        $ManagedRoot,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "$Name resolved outside Bootstrap managed MSVC: $ExecutablePath"
    }
    return $ExecutablePath
}
