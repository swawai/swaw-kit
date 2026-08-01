Set-StrictMode -Version 2.0

function Enter-ProjDataRootLock {
    param([Parameter(Mandatory = $true)][string]$DataDirectory)

    [void][IO.Directory]::CreateDirectory($DataDirectory)
    $DataDirectoryItem = Get-Item -LiteralPath $DataDirectory -Force
    if (($DataDirectoryItem.Attributes -band
        [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw (
            'Project data directory cannot be a reparse point: ' +
            $DataDirectory
        )
    }
    $LockPath = Join-Path $DataDirectory '_proj-entry.lock'
    foreach ($Attempt in 1..100) {
        try {
            return [IO.FileStream]::new(
                $LockPath,
                [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None
            )
        } catch [IO.IOException] {
            if ($Attempt -eq 100) {
                throw "Timed out waiting for the project DataRoot lock: $LockPath"
            }
            Start-Sleep -Milliseconds 50
        }
    }
}

function Move-ProjLegacyDataRoot {
    param([Parameter(Mandatory = $true)][object]$Plan)

    if ([IO.Directory]::Exists($Plan.DataRoot)) {
        throw "Legacy migration target already exists: $($Plan.DataRoot)"
    }
    if (-not [IO.Directory]::Exists($Plan.SourceDataRoot)) {
        throw "Legacy DataRoot disappeared: $($Plan.SourceDataRoot)"
    }
    $SourceVolume = [IO.Path]::GetPathRoot(
        [IO.Path]::GetFullPath([string]$Plan.SourceDataRoot)
    )
    $TargetVolume = [IO.Path]::GetPathRoot(
        [IO.Path]::GetFullPath([string]$Plan.DataRoot)
    )
    if (-not $SourceVolume.Equals(
        $TargetVolume,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw (
            'The legacy DataRoot is on another volume and cannot be ' +
            'migrated atomically. Move it manually, then retry: ' +
            "'$($Plan.SourceDataRoot)' -> '$($Plan.DataRoot)'"
        )
    }
    Write-Host (
        '[MIGRATE] Moving legacy DataRoot into Swaw Kit Home: ' +
        "$($Plan.SourceDataRoot) -> $($Plan.DataRoot)"
    ) -ForegroundColor Cyan
    [IO.Directory]::Move(
        [string]$Plan.SourceDataRoot,
        [string]$Plan.DataRoot
    )
}

function Complete-ProjDataRootPlan {
    param([Parameter(Mandatory = $true)][object]$Plan)

    switch ([string]$Plan.Kind) {
        'Direct' {
            return [string]$Plan.DataRoot
        }
        'Create' {
            [void][IO.Directory]::CreateDirectory($Plan.DataRoot)
        }
        'ClaimCurrent' {
            if (-not [IO.Directory]::Exists($Plan.DataRoot)) {
                throw "Claim target disappeared: $($Plan.DataRoot)"
            }
        }
        'ClaimRename' {
            if ([IO.Directory]::Exists($Plan.DataRoot)) {
                throw "Claim rename target already exists: $($Plan.DataRoot)"
            }
            if (-not [IO.Directory]::Exists($Plan.SourceDataRoot)) {
                throw "Claim rename source disappeared: $($Plan.SourceDataRoot)"
            }
            [IO.Directory]::Move(
                [string]$Plan.SourceDataRoot,
                [string]$Plan.DataRoot
            )
        }
        'MigrateLegacy' {
            Move-ProjLegacyDataRoot -Plan $Plan
        }
        'ClaimMigrateLegacy' {
            Move-ProjLegacyDataRoot -Plan $Plan
        }
        default {
            throw "Unsupported DataRoot plan kind '$($Plan.Kind)'."
        }
    }
    Write-ProjEntryIdentityRecord `
        -DataRoot $Plan.DataRoot `
        -EntryName $Plan.EntryName `
        -EntryFile $Plan.EntryFile `
        -Identity $Plan.Identity
    return [string]$Plan.DataRoot
}

function Test-ProjDataRootClaimStateStable {
    param(
        [Parameter(Mandatory = $true)][object]$InitialPlan,
        [Parameter(Mandatory = $true)][object]$CurrentPlan
    )

    foreach ($Property in @('EntryFile', 'DataRoot')) {
        if (-not ([string]$InitialPlan.$Property).Equals(
            [string]$CurrentPlan.$Property,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            return $false
        }
    }
    if (-not ([string]$InitialPlan.EntryName).Equals(
        [string]$CurrentPlan.EntryName,
        [StringComparison]::OrdinalIgnoreCase
    ) -or
        [string]$InitialPlan.Identity.Key -cne
            [string]$CurrentPlan.Identity.Key) {
        return $false
    }
    if ([string]$CurrentPlan.Kind -ceq 'Direct') {
        return $true
    }
    return (
        [string]$CurrentPlan.Kind -ceq [string]$InitialPlan.Kind -and
        ([string]$CurrentPlan.SourceDataRoot).Equals(
            [string]$InitialPlan.SourceDataRoot,
            [StringComparison]::OrdinalIgnoreCase
        )
    )
}

function Repair-ProjMovedDevelopmentEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$LegacyDataRoot,
        [Parameter(Mandatory = $true)][string]$EntryName
    )

    if ([string]::IsNullOrWhiteSpace($LegacyDataRoot) -or
        $DataRoot.Equals(
            $LegacyDataRoot,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        return
    }
    $EnvironmentRoot = Join-Path $DataRoot 'dev_env'
    $EnvironmentFiles = @(
        [pscustomobject]@{
            Path = Join-Path $EnvironmentRoot 'env.cmd'
            Marker = 'Generated by Swaw Kit Proj.'
        },
        [pscustomobject]@{
            Path = Join-Path $EnvironmentRoot 'env.ps1'
            Marker = 'Generated by Swaw Kit Proj.'
        }
    )
    $Stale = $false
    foreach ($File in $EnvironmentFiles) {
        if (-not [IO.File]::Exists($File.Path)) {
            continue
        }
        $Content = [IO.File]::ReadAllText($File.Path)
        if ($Content.IndexOf(
            $LegacyDataRoot,
            [StringComparison]::OrdinalIgnoreCase
        ) -ge 0) {
            $Stale = $true
        }
    }
    if (-not $Stale) {
        return
    }

    foreach ($File in $EnvironmentFiles) {
        if (-not [IO.File]::Exists($File.Path)) {
            continue
        }
        $Content = [IO.File]::ReadAllText($File.Path)
        if (-not $Content.Contains([string]$File.Marker)) {
            throw (
                'A stale development environment file is not recognized as ' +
                "generated content: $($File.Path). Manual repair is required."
            )
        }
    }
    foreach ($File in $EnvironmentFiles) {
        if ([IO.File]::Exists($File.Path)) {
            [IO.File]::Delete($File.Path)
        }
    }
    Write-Warning (
        'The migrated development environment contained old absolute paths. ' +
        "Run '$EntryName .dev.setup' once to republish env.cmd and env.ps1."
    )
}

function Remove-ProjLegacyDataDirectoryResidue {
    param([Parameter(Mandatory = $true)][string]$LegacyDataRoot)

    $LegacyDataDirectory = Split-Path -Path $LegacyDataRoot -Parent
    if (-not [IO.Directory]::Exists($LegacyDataDirectory)) {
        return
    }
    try {
        $LockPath = Join-Path $LegacyDataDirectory '_proj-entry.lock'
        if ([IO.File]::Exists($LockPath) -and
            (Get-Item -LiteralPath $LockPath -Force).Length -eq 0) {
            [IO.File]::Delete($LockPath)
        }
        if (@(Get-ChildItem `
            -LiteralPath $LegacyDataDirectory `
            -Force).Count -eq 0) {
            [IO.Directory]::Delete($LegacyDataDirectory)
        }
    } catch {
        Write-Warning (
            'The obsolete project-local data directory could not be fully ' +
            "cleaned: $LegacyDataDirectory. $($_.Exception.Message)"
        )
    }
}

function Set-ProjResolvedDataRoot {
    param(
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$LegacyDataRoot,
        [Parameter(Mandatory = $true)][string]$EntryName
    )

    Repair-ProjMovedDevelopmentEnvironment `
        -DataRoot $DataRoot `
        -LegacyDataRoot $LegacyDataRoot `
        -EntryName $EntryName
    if (-not $DataRoot.Equals(
        $LegacyDataRoot,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        Remove-ProjLegacyDataDirectoryResidue `
            -LegacyDataRoot $LegacyDataRoot
    }
    $env:SWAWKIT_PROJ_DATA_ROOT = $DataRoot
    return $DataRoot
}
