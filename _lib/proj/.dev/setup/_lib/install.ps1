Set-StrictMode -Version 2.0

function Copy-ProjDevPayload {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    [void][IO.Directory]::CreateDirectory($Destination)
    foreach ($Item in Get-ChildItem -LiteralPath $Source -Force) {
        Copy-Item `
            -LiteralPath $Item.FullName `
            -Destination $Destination `
            -Recurse `
            -Force
    }
}

function Test-ProjDevStagedPayload {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Definition,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [AllowNull()][scriptblock]$Validate
    )

    if (-not (Test-ProjDevRequiredFiles `
        -Root $InstallRoot `
        -RelativePaths ([string[]]$Definition.RequiredPaths)
    )) {
        return $false
    }
    if ($null -eq $Validate) {
        return $true
    }

    $Result = @(& $Validate $Context $Definition $InstallRoot)
    if ($Result.Count -ne 1 -or $Result[0] -isnot [bool]) {
        throw "The $($Definition.Name) validator must return exactly one Boolean."
    }
    return [bool]$Result[0]
}

function Publish-ProjDevInstallDirectory {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Definition,
        [Parameter(Mandatory = $true)][string]$StagedPath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    $TargetPath = Get-ProjDevFullPath -Path $TargetPath
    $StagedPath = Get-ProjDevFullPath -Path $StagedPath
    [void][IO.Directory]::CreateDirectory(
        (Split-Path -Path $TargetPath -Parent)
    )
    $BackupPath = "$TargetPath.backup-$([Guid]::NewGuid().ToString('N'))"
    $BackupKind = ''
    $Published = $false

    try {
        if ([IO.Directory]::Exists($TargetPath)) {
            [IO.Directory]::Move($TargetPath, $BackupPath)
            $BackupKind = 'directory'
        } elseif ([IO.File]::Exists($TargetPath)) {
            [IO.File]::Move($TargetPath, $BackupPath)
            $BackupKind = 'file'
        }
        [IO.Directory]::Move($StagedPath, $TargetPath)
        $Published = $true
        if (-not (Test-ProjDevInstalled `
            -Context $Context `
            -Definition $Definition
        )) {
            throw "Published $($Definition.Name) installation failed validation."
        }
    } catch {
        if ($Published -and
            ([IO.Directory]::Exists($TargetPath) -or
             [IO.File]::Exists($TargetPath))) {
            Remove-ProjDevControlledPath `
                -Path $TargetPath `
                -DataRoot $Context.DataRoot `
                -Activity 'rolling back a failed installation'
        }
        if (-not [string]::IsNullOrWhiteSpace($BackupKind)) {
            if ($BackupKind -eq 'directory' -and
                [IO.Directory]::Exists($BackupPath)) {
                [IO.Directory]::Move($BackupPath, $TargetPath)
                $BackupKind = ''
            } elseif ($BackupKind -eq 'file' -and
                [IO.File]::Exists($BackupPath)) {
                [IO.File]::Move($BackupPath, $TargetPath)
                $BackupKind = ''
            }
        }
        throw
    } finally {
        if ([IO.Directory]::Exists($StagedPath)) {
            Remove-ProjDevControlledPath `
                -Path $StagedPath `
                -DataRoot $Context.DataRoot `
                -Activity 'cleaning a staged installation'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($BackupKind) -and
        ([IO.Directory]::Exists($BackupPath) -or
         [IO.File]::Exists($BackupPath))) {
        try {
            Remove-ProjDevControlledPath `
                -Path $BackupPath `
                -DataRoot $Context.DataRoot `
                -Activity 'cleaning a replaced installation'
        } catch {
            Write-Warning "Replaced installation could not be removed: $BackupPath"
        }
    }
}

function Install-ProjDevArchiveTool {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Definition,
        [AllowNull()][scriptblock]$Prepare = $null,
        [AllowNull()][scriptblock]$Validate = $null
    )

    Assert-ProjDevArchiveDefinition -Definition $Definition
    if (Test-ProjDevInstalled -Context $Context -Definition $Definition) {
        return $false
    }

    Write-Host "[STEP] Installing $($Definition.Name) $($Definition.Version)..." `
        -ForegroundColor Cyan
    $ArchivePath = Get-ProjDevVerifiedArchive `
        -Context $Context `
        -Definition $Definition
    $Target = Get-ProjDevInstallRoot `
        -Context $Context `
        -Definition $Definition
    $Parent = Split-Path -Path $Target -Parent
    [void][IO.Directory]::CreateDirectory($Parent)
    $Token = [Guid]::NewGuid().ToString('N')
    $WorkRoot = Join-Path $Parent ".work-$Token"
    $ExtractRoot = Join-Path $WorkRoot 'extract'
    $StagedRoot = Join-Path $Parent ".partial-$Token"

    try {
        Write-Host "[EXT] $([IO.Path]::GetFileName($ArchivePath))" `
            -ForegroundColor DarkGray
        Expand-ProjDevZipSafely `
            -ArchivePath $ArchivePath `
            -Destination $ExtractRoot
        $SourceRoot = if ([string]::IsNullOrWhiteSpace(
            [string]$Definition.ArchiveSubdir
        )) {
            $ExtractRoot
        } else {
            Resolve-ProjDevChildPath `
                -Root $ExtractRoot `
                -RelativePath ([string]$Definition.ArchiveSubdir) `
                -Description 'archive subdirectory'
        }
        if (-not [IO.Directory]::Exists($SourceRoot)) {
            throw "Archive subdirectory is missing: $($Definition.ArchiveSubdir)"
        }

        Copy-ProjDevPayload -Source $SourceRoot -Destination $StagedRoot
        if ($null -ne $Prepare) {
            [void](& $Prepare $StagedRoot)
        }
        if (-not (Test-ProjDevStagedPayload `
            -Context $Context `
            -Definition $Definition `
            -InstallRoot $StagedRoot `
            -Validate $Validate
        )) {
            throw "Staged $($Definition.Name) payload failed validation."
        }
        Write-ProjDevInstallMetadata `
            -Definition $Definition `
            -InstallRoot $StagedRoot
        Publish-ProjDevInstallDirectory `
            -Context $Context `
            -Definition $Definition `
            -StagedPath $StagedRoot `
            -TargetPath $Target
        return $true
    } finally {
        foreach ($CleanupPath in @($StagedRoot, $WorkRoot)) {
            if ([IO.Directory]::Exists($CleanupPath) -or
                [IO.File]::Exists($CleanupPath)) {
                Remove-ProjDevControlledPath `
                    -Path $CleanupPath `
                    -DataRoot $Context.DataRoot `
                    -Activity 'cleaning installation work data'
            }
        }
    }
}
