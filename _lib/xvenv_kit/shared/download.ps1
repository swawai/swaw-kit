Set-StrictMode -Version 2.0

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Test-XvenvRequiredPaths {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string[]]$RelativePaths
    )

    foreach ($RelativePath in $RelativePaths) {
        $RequiredPath = Resolve-XvenvChildPath -Root $Root -RelativePath $RelativePath -Description 'required path'
        if (-not [IO.File]::Exists($RequiredPath) -or (Get-Item -LiteralPath $RequiredPath).Length -le 0) {
            return $false
        }
    }
    return $true
}

function Resolve-XvenvChildPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath)) {
        throw "Invalid $Description '$RelativePath': expected a non-empty relative path."
    }
    $FullRoot = Get-XvenvFullPath $Root
    $RootPrefix = $FullRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $FullPath = Get-XvenvFullPath (Join-Path $FullRoot $RelativePath)
    if (-not $FullPath.StartsWith($RootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Invalid $Description '$RelativePath': path escapes its root."
    }
    return $FullPath
}

function Test-XvenvFileSha256 {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Expected
    )

    $Actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    return $Actual -eq $Expected.ToLowerInvariant()
}

function Get-XvenvArtifactCacheRoot {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Definition
    )

    $Name = Get-XvenvSafeSegment -Value ([string]$Definition.Name) -Description 'artifact name'
    $Version = Get-XvenvSafeSegment -Value ([string]$Definition.Version) -Description 'artifact version'
    $Subdir = [string]$Definition.ArchiveSubdir
    $ExpectedSha256 = Get-XvenvExpectedSha256 $Definition
    $SourceKey = Get-XvenvSha256 "$($Definition.Url)`n$Subdir`n$ExpectedSha256"
    return Join-Path (Join-Path (Join-Path $Context.DataRoot 'cache\downloads') $Name) "$Version-$($SourceKey.Substring(0, 16))"
}

function Get-XvenvSourceFileName {
    param([Parameter(Mandatory = $true)][string]$Source)

    if ([IO.File]::Exists($Source)) {
        return [IO.Path]::GetFileName($Source)
    }
    try {
        $Uri = [Uri]$Source
        $Name = [Uri]::UnescapeDataString([IO.Path]::GetFileName($Uri.AbsolutePath))
        if (-not [string]::IsNullOrWhiteSpace($Name)) {
            return $Name
        }
    } catch {
        throw "Invalid download source: $Source"
    }
    throw "Cannot determine the archive name from: $Source"
}

function Invoke-XvenvDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $Parent = Split-Path $Destination -Parent
    [void][IO.Directory]::CreateDirectory($Parent)
    $TemporaryPath = Join-Path $Parent (".$([IO.Path]::GetFileName($Destination)).$([Guid]::NewGuid().ToString('N')).tmp")

    try {
        Write-Host "[DL] $([IO.Path]::GetFileName($Destination))" -ForegroundColor DarkGray
        if ([IO.File]::Exists($Source)) {
            [IO.File]::Copy((Get-XvenvFullPath $Source), $TemporaryPath, $false)
        } else {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $Downloaded = $false
            try {
                Import-Module BitsTransfer -ErrorAction Stop
                Start-BitsTransfer -Source $Source -Destination $TemporaryPath -ErrorAction Stop
                $Downloaded = $true
            } catch {
                if ([IO.File]::Exists($TemporaryPath)) {
                    [IO.File]::Delete($TemporaryPath)
                }
            }
            if (-not $Downloaded) {
                Invoke-WebRequest -Uri $Source -OutFile $TemporaryPath -UseBasicParsing
            }
        }
        [IO.File]::Move($TemporaryPath, $Destination)
    } catch {
        throw "Download failed for '$Source': $($_.Exception.Message)"
    } finally {
        if ([IO.File]::Exists($TemporaryPath)) {
            [IO.File]::Delete($TemporaryPath)
        }
    }
}

function Test-XvenvZipArchive {
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

function Expand-XvenvZipSafely {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $Destination = Get-XvenvFullPath $Destination
    [void][IO.Directory]::CreateDirectory($Destination)
    $DestinationPrefix = $Destination.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
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

            $RelativePath = $Entry.FullName.Replace('/', [IO.Path]::DirectorySeparatorChar)
            if ([string]::IsNullOrWhiteSpace($RelativePath)) {
                continue
            }
            $Target = Get-XvenvFullPath (Join-Path $Destination $RelativePath)
            if (-not $Target.StartsWith($DestinationPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Archive entry escapes the extraction directory: $($Entry.FullName)"
            }

            if ($Entry.FullName.EndsWith('/')) {
                [void][IO.Directory]::CreateDirectory($Target)
                continue
            }

            [void][IO.Directory]::CreateDirectory((Split-Path $Target -Parent))
            $InputStream = $Entry.Open()
            try {
                $OutputStream = [IO.File]::Open($Target, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
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

function Get-XvenvCachedPayload {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Definition
    )

    $CacheRoot = Get-XvenvArtifactCacheRoot -Context $Context -Definition $Definition
    $ExpectedSha256 = Get-XvenvExpectedSha256 $Definition
    $PayloadPath = Join-Path $CacheRoot 'payload'
    if (Test-XvenvRequiredPaths -Root $PayloadPath -RelativePaths ([string[]]$Definition.RequiredPaths)) {
        return $PayloadPath
    }

    $ArtifactKey = Get-XvenvSha256 $CacheRoot
    $LockPath = Join-Path (Join-Path $Context.DataRoot 'locks\artifacts') "$ArtifactKey.lock"
    $Lock = Enter-XvenvFileLock -Path $LockPath
    try {
        if (Test-XvenvRequiredPaths -Root $PayloadPath -RelativePaths ([string[]]$Definition.RequiredPaths)) {
            return $PayloadPath
        }

        if ([IO.File]::Exists($CacheRoot)) {
            Remove-XvenvControlledPath -Path $CacheRoot -Root $Context.DataRoot -Context 'repairing an invalid artifact cache root'
        }
        if ([IO.Directory]::Exists($PayloadPath) -or [IO.File]::Exists($PayloadPath)) {
            Remove-XvenvControlledPath -Path $PayloadPath -Root $Context.DataRoot -Context 'repairing an incomplete artifact cache'
        }
        [void][IO.Directory]::CreateDirectory($CacheRoot)

        $ArchiveName = Get-XvenvSourceFileName ([string]$Definition.Url)
        $ArchivePath = Join-Path $CacheRoot $ArchiveName
        if ([IO.Directory]::Exists($ArchivePath)) {
            Remove-XvenvControlledPath -Path $ArchivePath -Root $Context.DataRoot -Context 'repairing an invalid cached archive'
        }
        if ([IO.File]::Exists($ArchivePath) -and
            (-not (Test-XvenvFileSha256 -Path $ArchivePath -Expected $ExpectedSha256) -or
             -not (Test-XvenvZipArchive $ArchivePath))) {
            Remove-XvenvControlledPath -Path $ArchivePath -Root $Context.DataRoot -Context 'removing a corrupt cached archive'
        }
        if (-not [IO.File]::Exists($ArchivePath)) {
            Invoke-XvenvDownload -Source ([string]$Definition.Url) -Destination $ArchivePath
        }
        if (-not (Test-XvenvFileSha256 -Path $ArchivePath -Expected $ExpectedSha256)) {
            Remove-XvenvControlledPath -Path $ArchivePath -Root $Context.DataRoot -Context 'removing a download with the wrong checksum'
            throw "SHA-256 verification failed for: $ArchiveName"
        }
        if (-not (Test-XvenvZipArchive $ArchivePath)) {
            Remove-XvenvControlledPath -Path $ArchivePath -Root $Context.DataRoot -Context 'removing an invalid downloaded archive'
            throw "Downloaded archive is invalid: $ArchiveName"
        }

        $ExtractRoot = Join-Path $CacheRoot (".extract-$([Guid]::NewGuid().ToString('N'))")
        try {
            Write-Host "[EXT] $ArchiveName" -ForegroundColor DarkGray
            Expand-XvenvZipSafely -ArchivePath $ArchivePath -Destination $ExtractRoot
            $SourceRoot = if ([string]::IsNullOrWhiteSpace([string]$Definition.ArchiveSubdir)) {
                $ExtractRoot
            } else {
                Resolve-XvenvChildPath `
                    -Root $ExtractRoot `
                    -RelativePath ([string]$Definition.ArchiveSubdir) `
                    -Description 'archive subdirectory'
            }
            if (-not (Test-XvenvRequiredPaths -Root $SourceRoot -RelativePaths ([string[]]$Definition.RequiredPaths))) {
                throw "Archive '$ArchiveName' does not contain the required xvenv payload."
            }

            [IO.Directory]::Move((Get-XvenvFullPath $SourceRoot), $PayloadPath)
        } finally {
            if ([IO.Directory]::Exists($ExtractRoot)) {
                Remove-XvenvControlledPath -Path $ExtractRoot -Root $Context.DataRoot -Context 'cleaning an extraction directory'
            }
        }
        return $PayloadPath
    } finally {
        $Lock.Dispose()
    }
}
