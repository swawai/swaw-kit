Set-StrictMode -Version 2.0

function Test-ProjDevPathExists {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [IO.Directory]::Exists($Path) -or [IO.File]::Exists($Path)
}

function Remove-ProjDevControlledPathWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$Activity,
        [int]$Attempts = 5
    )

    $LastError = $null
    for ($Attempt = 1; $Attempt -le $Attempts; $Attempt++) {
        if (-not (Test-ProjDevPathExists -Path $Path)) {
            return
        }
        try {
            Remove-ProjDevControlledPath `
                -Path $Path `
                -DataRoot $DataRoot `
                -Activity $Activity
            if (-not (Test-ProjDevPathExists -Path $Path)) {
                return
            }
        } catch {
            $LastError = $_
        }
        if ($Attempt -lt $Attempts) {
            Start-Sleep -Milliseconds (150 * $Attempt)
        }
    }

    $Detail = if ($null -eq $LastError) {
        'the path still exists'
    } else {
        $LastError.Exception.Message
    }
    throw (
        "Cannot finish $Activity after $Attempts attempts: $Path. " +
        "Release processes that lock the path, then run .dev.setup again. " +
        "Last error: $Detail"
    )
}

function Move-ProjDevControlledPathWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$Activity,
        [int]$Attempts = 5
    )

    $Source = Assert-ProjDevPathInsideDataRoot `
        -Path $Source `
        -DataRoot $DataRoot `
        -Activity $Activity
    $Destination = Assert-ProjDevPathInsideDataRoot `
        -Path $Destination `
        -DataRoot $DataRoot `
        -Activity $Activity
    [void][IO.Directory]::CreateDirectory(
        (Split-Path -Path $Destination -Parent)
    )

    $LastError = $null
    for ($Attempt = 1; $Attempt -le $Attempts; $Attempt++) {
        if (-not (Test-ProjDevPathExists -Path $Source)) {
            throw "Cannot $Activity because the source is missing: $Source"
        }
        if (Test-ProjDevPathExists -Path $Destination) {
            throw "Cannot $Activity because the destination exists: $Destination"
        }
        try {
            if ([IO.Directory]::Exists($Source)) {
                [IO.Directory]::Move($Source, $Destination)
            } elseif ([IO.File]::Exists($Source)) {
                [IO.File]::Move($Source, $Destination)
            } else {
                throw "Cannot $Activity because the source is missing: $Source"
            }
            return
        } catch {
            $LastError = $_
        }
        if ($Attempt -lt $Attempts) {
            Start-Sleep -Milliseconds (150 * $Attempt)
        }
    }
    throw (
        "Cannot finish $Activity after $Attempts attempts. " +
        "Release processes that lock '$Source', then run .dev.setup again. " +
        "Last error: $($LastError.Exception.Message)"
    )
}

function Invoke-ProjDevInstallCandidateValidation {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Definition,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [AllowNull()][scriptblock]$ValidateCandidate = $null
    )

    $Result = @(if ($null -eq $ValidateCandidate) {
        Test-ProjDevInstalled `
            -Context $Context `
            -Definition $Definition `
            -InstallRoot $InstallRoot
    } else {
        & $ValidateCandidate $Context $Definition $InstallRoot
    })
    if ($Result.Count -ne 1 -or $Result[0] -isnot [bool]) {
        throw (
            "The $($Definition.Name) installation validator must return " +
            'exactly one Boolean.'
        )
    }
    return [bool]$Result[0]
}

function New-ProjDevInstallWorkPath {
    param(
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)]
        [ValidateSet('partial', 'work')]
        [string]$Kind
    )

    $TargetPath = Get-ProjDevFullPath -Path $TargetPath
    $Leaf = [IO.Path]::GetFileName($TargetPath)
    return Join-Path (Split-Path -Path $TargetPath -Parent) (
        ".$Leaf.$Kind-$([Guid]::NewGuid().ToString('N'))"
    )
}

function Get-ProjDevInstallRecoveryPaths {
    param([Parameter(Mandatory = $true)][string]$TargetPath)

    $TargetPath = Get-ProjDevFullPath -Path $TargetPath
    $Parent = Split-Path -Path $TargetPath -Parent
    $Leaf = [IO.Path]::GetFileName($TargetPath)
    if (-not [IO.Directory]::Exists($Parent)) {
        return [pscustomobject]@{
            Backups = @()
            Work = @()
        }
    }

    $Backups = [Collections.Generic.List[string]]::new()
    $Work = [Collections.Generic.List[string]]::new()
    foreach ($Item in Get-ChildItem -LiteralPath $Parent -Force) {
        $Name = [string]$Item.Name
        if ($Name.StartsWith(
            "$Leaf.backup-",
            [StringComparison]::OrdinalIgnoreCase
        )) {
            $Backups.Add([string]$Item.FullName)
        } elseif (
            $Name.StartsWith(
                ".$Leaf.partial-",
                [StringComparison]::OrdinalIgnoreCase
            ) -or
            $Name.StartsWith(
                ".$Leaf.work-",
                [StringComparison]::OrdinalIgnoreCase
            ) -or
            $Name.StartsWith(
                '.partial-',
                [StringComparison]::OrdinalIgnoreCase
            ) -or
            $Name.StartsWith(
                '.work-',
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            $Work.Add([string]$Item.FullName)
        }
    }
    return [pscustomobject]@{
        Backups = [string[]]$Backups.ToArray()
        Work = [string[]]$Work.ToArray()
    }
}

function Remove-ProjDevInstallResidues {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Paths,
        [Parameter(Mandatory = $true)][string]$Activity
    )

    foreach ($Path in $Paths) {
        if (-not (Test-ProjDevPathExists -Path $Path)) {
            continue
        }
        try {
            Remove-ProjDevControlledPathWithRetry `
                -Path $Path `
                -DataRoot $Context.DataRoot `
                -Activity $Activity
        } catch {
            Write-Warning $_.Exception.Message
        }
    }
}

function Repair-ProjDevInstallState {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Definition,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [AllowNull()][scriptblock]$ValidateCandidate = $null
    )

    $TargetPath = Assert-ProjDevPathInsideDataRoot `
        -Path $TargetPath `
        -DataRoot $Context.DataRoot `
        -Activity 'repairing an interrupted installation'
    [void][IO.Directory]::CreateDirectory(
        (Split-Path -Path $TargetPath -Parent)
    )
    $RecoveryPaths = Get-ProjDevInstallRecoveryPaths `
        -TargetPath $TargetPath
    $TargetReady = (Test-ProjDevPathExists -Path $TargetPath) -and
        (Invoke-ProjDevInstallCandidateValidation `
            -Context $Context `
            -Definition $Definition `
            -InstallRoot $TargetPath `
            -ValidateCandidate $ValidateCandidate)

    if ($TargetReady) {
        Remove-ProjDevInstallResidues `
            -Context $Context `
            -Paths ([string[]]@(
                $RecoveryPaths.Backups
                $RecoveryPaths.Work
            )) `
            -Activity 'cleaning stale installation recovery data'
        return [pscustomobject]@{
            Ready = $true
            Restored = $false
        }
    }

    $ValidBackups = @($RecoveryPaths.Backups | Where-Object {
        Invoke-ProjDevInstallCandidateValidation `
            -Context $Context `
            -Definition $Definition `
            -InstallRoot $_ `
            -ValidateCandidate $ValidateCandidate
    } | Sort-Object)
    if (Test-ProjDevPathExists -Path $TargetPath) {
        Remove-ProjDevControlledPathWithRetry `
            -Path $TargetPath `
            -DataRoot $Context.DataRoot `
            -Activity 'removing an invalid installation'
    }

    if ($ValidBackups.Count -gt 0) {
        $SelectedBackup = [string]$ValidBackups[-1]
        Move-ProjDevControlledPathWithRetry `
            -Source $SelectedBackup `
            -Destination $TargetPath `
            -DataRoot $Context.DataRoot `
            -Activity 'restoring the last valid installation'
        if (-not (Invoke-ProjDevInstallCandidateValidation `
            -Context $Context `
            -Definition $Definition `
            -InstallRoot $TargetPath `
            -ValidateCandidate $ValidateCandidate)) {
            throw (
                "The restored $($Definition.Name) installation failed " +
                "validation: $TargetPath"
            )
        }
        Write-Host (
            "[RECOVER] Restored $($Definition.Name) from an interrupted " +
            'installation.'
        ) -ForegroundColor Yellow
        $RecoveryPaths = Get-ProjDevInstallRecoveryPaths `
            -TargetPath $TargetPath
        Remove-ProjDevInstallResidues `
            -Context $Context `
            -Paths ([string[]]@(
                $RecoveryPaths.Backups
                $RecoveryPaths.Work
            )) `
            -Activity 'cleaning stale installation recovery data'
        return [pscustomobject]@{
            Ready = $true
            Restored = $true
        }
    }

    Remove-ProjDevInstallResidues `
        -Context $Context `
        -Paths ([string[]]@(
            $RecoveryPaths.Backups
            $RecoveryPaths.Work
        )) `
        -Activity 'discarding interrupted installation data'
    return [pscustomobject]@{
        Ready = $false
        Restored = $false
    }
}

function Clear-ProjDevArtifactCache {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Definition
    )

    $CacheRoot = Get-ProjDevArtifactCacheRoot `
        -Context $Context `
        -Definition $Definition
    $ArtifactKey = Get-ProjDevSha256Text -Value $CacheRoot
    $Lock = Enter-ProjDevFileLock -Path (
        Join-Path $Context.ArtifactLockRoot "$ArtifactKey.lock"
    )
    try {
        if (Test-ProjDevPathExists -Path $CacheRoot) {
            Remove-ProjDevControlledPathWithRetry `
                -Path $CacheRoot `
                -DataRoot $Context.DataRoot `
                -Activity 'resetting a failed artifact cache'
        }
    } finally {
        $Lock.Dispose()
    }
}
