Set-StrictMode -Version 2.0

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-ProjDevSourceFileName {
    param([Parameter(Mandatory = $true)][string]$Source)

    if ([IO.File]::Exists($Source)) {
        return [IO.Path]::GetFileName((Get-ProjDevFullPath -Path $Source))
    }
    try {
        $Uri = [Uri]$Source
        $Name = [Uri]::UnescapeDataString(
            [IO.Path]::GetFileName($Uri.AbsolutePath)
        )
        if (-not [string]::IsNullOrWhiteSpace($Name)) {
            return $Name
        }
    } catch {
        throw "Invalid download source: $Source"
    }
    throw "Cannot determine the archive name from: $Source"
}

function Get-ProjDevArtifactCacheRoot {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Definition
    )

    $Name = Get-ProjDevSafeSegment `
        -Value ([string]$Definition.Name) `
        -Description 'artifact name'
    $Version = Get-ProjDevSafeSegment `
        -Value ([string]$Definition.Version) `
        -Description 'artifact version'
    $SourceIdentity = [string]::Join("`n", [string[]]@(
        [string]$Definition.SourceIdentity,
        [string]$Definition.ArchiveSubdir,
        (Get-ProjDevProjectSha256 -Definition $Definition)
    ))
    $SourceKey = Get-ProjDevSha256Text -Value $SourceIdentity
    return Join-Path (Join-Path $Context.CacheRoot $Name) (
        "$Version-$($SourceKey.Substring(0, 16))"
    )
}

function Remove-ProjDevDownloadTemporaryFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([IO.File]::Exists($Path)) {
        [IO.File]::Delete($Path)
    }
}

function Invoke-ProjDevDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $Parent = Split-Path -Path $Destination -Parent
    [void][IO.Directory]::CreateDirectory($Parent)
    $TemporaryPath = Join-Path $Parent (
        ".$([IO.Path]::GetFileName($Destination))." +
        "$([Guid]::NewGuid().ToString('N')).tmp"
    )
    $Failures = [Collections.Generic.List[string]]::new()

    try {
        Write-Host "[DL] $([IO.Path]::GetFileName($Destination))" `
            -ForegroundColor DarkGray
        if ([IO.File]::Exists($Source)) {
            [IO.File]::Copy(
                (Get-ProjDevFullPath -Path $Source),
                $TemporaryPath,
                $false
            )
        } else {
            $Downloaded = $false
            $Curl = Get-Command curl.exe `
                -CommandType Application `
                -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($null -ne $Curl) {
                try {
                    [string[]]$CurlArguments = @(
                        '--silent',
                        '--show-error',
                        '--fail',
                        '--location',
                        '--retry', '3',
                        '--retry-delay', '2',
                        '--connect-timeout', '30',
                        '--output', $TemporaryPath,
                        $Source
                    )
                    & $Curl.Source @CurlArguments
                    if ($LASTEXITCODE -eq 0 -and
                        [IO.File]::Exists($TemporaryPath)) {
                        $Downloaded = $true
                    } else {
                        $Failures.Add("curl exited with code $LASTEXITCODE")
                    }
                } catch {
                    $Failures.Add("curl: $($_.Exception.Message)")
                }
                if (-not $Downloaded) {
                    Remove-ProjDevDownloadTemporaryFile -Path $TemporaryPath
                }
            }

            if (-not $Downloaded) {
                try {
                    Import-Module BitsTransfer -ErrorAction Stop
                    Start-BitsTransfer `
                        -Source $Source `
                        -Destination $TemporaryPath `
                        -ErrorAction Stop
                    $Downloaded = $true
                } catch {
                    $Failures.Add("BITS: $($_.Exception.Message)")
                    Remove-ProjDevDownloadTemporaryFile -Path $TemporaryPath
                }
            }

            if (-not $Downloaded) {
                $PreviousProtocol = [Net.ServicePointManager]::SecurityProtocol
                try {
                    [Net.ServicePointManager]::SecurityProtocol =
                        $PreviousProtocol -bor [Net.SecurityProtocolType]::Tls12
                    Invoke-WebRequest `
                        -Uri $Source `
                        -OutFile $TemporaryPath `
                        -UseBasicParsing `
                        -ErrorAction Stop
                    $Downloaded = $true
                } catch {
                    $Failures.Add("Invoke-WebRequest: $($_.Exception.Message)")
                    Remove-ProjDevDownloadTemporaryFile -Path $TemporaryPath
                } finally {
                    [Net.ServicePointManager]::SecurityProtocol = $PreviousProtocol
                }
            }

            if (-not $Downloaded) {
                throw ([string]::Join('; ', $Failures.ToArray()))
            }
        }

        if (-not [IO.File]::Exists($TemporaryPath) -or
            (Get-Item -LiteralPath $TemporaryPath).Length -le 0) {
            throw 'The downloaded file is empty.'
        }
        [IO.File]::Move($TemporaryPath, $Destination)
    } catch {
        throw "Download failed for '$Source': $($_.Exception.Message)"
    } finally {
        Remove-ProjDevDownloadTemporaryFile -Path $TemporaryPath
    }
}

function Test-ProjDevZipArchive {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $Archive = [IO.Compression.ZipFile]::OpenRead($Path)
        try {
            $null = $Archive.Entries.Count
        } finally {
            $Archive.Dispose()
        }
        return $true
    } catch {
        return $false
    }
}

function Expand-ProjDevZipSafely {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $Destination = Get-ProjDevFullPath -Path $Destination
    [void][IO.Directory]::CreateDirectory($Destination)
    $DestinationPrefix = $Destination.TrimEnd('\', '/') +
        [IO.Path]::DirectorySeparatorChar
    $Archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    $EntryCount = 0
    [long]$TotalBytes = 0
    $MaximumEntries = 200000
    [long]$MaximumSingleFileBytes = 4GB
    [long]$MaximumTotalBytes = 12GB

    try {
        foreach ($Entry in $Archive.Entries) {
            $EntryCount++
            if ($EntryCount -gt $MaximumEntries) {
                throw "Archive contains more than $MaximumEntries entries."
            }
            if ($Entry.Length -gt $MaximumSingleFileBytes) {
                throw "Archive entry is too large: $($Entry.FullName)"
            }
            $TotalBytes += $Entry.Length
            if ($TotalBytes -gt $MaximumTotalBytes) {
                throw 'Archive expands beyond the 12 GB safety limit.'
            }

            $RelativePath = $Entry.FullName.Replace(
                '/',
                [IO.Path]::DirectorySeparatorChar
            )
            if ([string]::IsNullOrWhiteSpace($RelativePath)) {
                continue
            }
            $Target = Get-ProjDevFullPath -Path (
                Join-Path $Destination $RelativePath
            )
            if (-not $Target.StartsWith(
                $DestinationPrefix,
                [StringComparison]::OrdinalIgnoreCase
            )) {
                throw "Archive entry escapes extraction: $($Entry.FullName)"
            }

            if ($Entry.FullName.EndsWith('/')) {
                [void][IO.Directory]::CreateDirectory($Target)
                continue
            }
            [void][IO.Directory]::CreateDirectory(
                (Split-Path -Path $Target -Parent)
            )
            $InputStream = $Entry.Open()
            try {
                $OutputStream = [IO.File]::Open(
                    $Target,
                    [IO.FileMode]::Create,
                    [IO.FileAccess]::Write,
                    [IO.FileShare]::None
                )
                try {
                    $InputStream.CopyTo($OutputStream)
                } finally {
                    $OutputStream.Dispose()
                }
            } finally {
                $InputStream.Dispose()
            }
        }
    } finally {
        $Archive.Dispose()
    }
}

function Get-ProjDevVerifiedArchive {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Definition
    )

    $CacheRoot = Get-ProjDevArtifactCacheRoot `
        -Context $Context `
        -Definition $Definition
    $ArtifactKey = Get-ProjDevSha256Text -Value $CacheRoot
    $LockPath = Join-Path $Context.ArtifactLockRoot "$ArtifactKey.lock"
    $Lock = Enter-ProjDevFileLock -Path $LockPath
    try {
        if ([IO.File]::Exists($CacheRoot)) {
            Remove-ProjDevControlledPath `
                -Path $CacheRoot `
                -DataRoot $Context.DataRoot `
                -Activity 'repairing an invalid artifact cache'
        }
        [void][IO.Directory]::CreateDirectory($CacheRoot)

        $ArchiveName = Get-ProjDevSourceFileName `
            -Source ([string]$Definition.Url)
        $ArchivePath = Join-Path $CacheRoot $ArchiveName
        if ([IO.Directory]::Exists($ArchivePath)) {
            Remove-ProjDevControlledPath `
                -Path $ArchivePath `
                -DataRoot $Context.DataRoot `
                -Activity 'repairing an invalid cached archive'
        }

        $Expected = Get-ProjDevExpectedSha256 -Definition $Definition
        if ([IO.File]::Exists($ArchivePath)) {
            $ValidCachedArchive = Test-ProjDevZipArchive -Path $ArchivePath
            if ($ValidCachedArchive -and
                -not [string]::IsNullOrWhiteSpace($Expected)) {
                $ValidCachedArchive =
                    (Get-ProjDevFileSha256 -Path $ArchivePath) -ceq $Expected
            }
            if (-not $ValidCachedArchive) {
                Remove-ProjDevControlledPath `
                    -Path $ArchivePath `
                    -DataRoot $Context.DataRoot `
                    -Activity 'removing a corrupt cached archive'
            }
        }

        if (-not [IO.File]::Exists($ArchivePath)) {
            Invoke-ProjDevDownload `
                -Source ([string]$Definition.Url) `
                -Destination $ArchivePath
        }
        $Actual = Get-ProjDevFileSha256 -Path $ArchivePath
        if (-not [string]::IsNullOrWhiteSpace($Expected) -and
            $Actual -cne $Expected) {
            Remove-ProjDevControlledPath `
                -Path $ArchivePath `
                -DataRoot $Context.DataRoot `
                -Activity 'removing a download with the wrong checksum'
            throw "SHA-256 verification failed for: $ArchiveName"
        }
        if ([string]::IsNullOrWhiteSpace($Expected)) {
            $Definition.Sha256 = $Actual
        }
        if (-not (Test-ProjDevZipArchive -Path $ArchivePath)) {
            Remove-ProjDevControlledPath `
                -Path $ArchivePath `
                -DataRoot $Context.DataRoot `
                -Activity 'removing an invalid downloaded archive'
            throw "Downloaded archive is not a valid ZIP file: $ArchiveName"
        }
        return $ArchivePath
    } finally {
        $Lock.Dispose()
    }
}
