[CmdletBinding()]
param(
    [ValidateSet('Ensure', 'Check')]
    [string]$Mode = 'Ensure',

    [string]$DataRoot = '',

    [string]$ManifestPath = '',

    [ValidateSet('', 'amd64', 'arm64')]
    [string]$Architecture = '',

    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.Path]::GetFullPath($Path)
}

function Assert-ControlledChildPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $fullRoot = (Get-FullPath $Root).TrimEnd('\', '/')
    $fullPath = Get-FullPath $Path
    $prefix = $fullRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify a path outside the GitHub CLI data root: $fullPath"
    }
    return $fullPath
}

function Remove-ControlledPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $fullPath = Assert-ControlledChildPath -Path $Path -Root $Root
    if ([IO.Directory]::Exists($fullPath)) {
        Remove-Item -LiteralPath $fullPath -Recurse -Force
    } elseif ([IO.File]::Exists($fullPath)) {
        Remove-Item -LiteralPath $fullPath -Force
    }
}

function Get-NativeArchitecture {
    $value = if (-not [string]::IsNullOrWhiteSpace($env:PROCESSOR_ARCHITEW6432)) {
        $env:PROCESSOR_ARCHITEW6432
    } else {
        $env:PROCESSOR_ARCHITECTURE
    }

    switch ($value.ToUpperInvariant()) {
        'AMD64' { return 'amd64' }
        'ARM64' { return 'arm64' }
        default { throw "Unsupported Windows architecture '$value'. GitHub CLI portable setup supports AMD64 and ARM64." }
    }
}

function Enter-RuntimeLock {
    param([Parameter(Mandatory = $true)][string]$Path)

    [void][IO.Directory]::CreateDirectory((Split-Path $Path -Parent))
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ($true) {
        try {
            return [IO.File]::Open($Path, 'OpenOrCreate', 'ReadWrite', 'None')
        } catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) {
                throw 'Timed out waiting for another GitHub CLI setup process.'
            }
            Start-Sleep -Milliseconds 100
        }
    }
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $algorithm.ComputeHash($stream)
        return -join @($bytes | ForEach-Object { $_.ToString('x2') })
    } finally {
        $algorithm.Dispose()
        $stream.Dispose()
    }
}

function Read-RuntimeManifest {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TargetArchitecture
    )

    if (-not [IO.File]::Exists($Path)) {
        throw "Runtime manifest not found: $Path"
    }
    try {
        $manifest = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "Runtime manifest is invalid JSON: $($_.Exception.Message)"
    }
    if ([string]$manifest.schema -ne 'swaw.github-cli-runtime.v1' -or
        [string]$manifest.version -notmatch '^\d+\.\d+\.\d+$') {
        throw 'Runtime manifest has an unsupported schema or version.'
    }
    $property = $manifest.assets.PSObject.Properties[$TargetArchitecture]
    if ($null -eq $property) {
        throw "Runtime manifest has no $TargetArchitecture asset."
    }
    $asset = $property.Value
    $expectedName = "gh_$($manifest.version)_windows_$TargetArchitecture.zip"
    if ([string]$asset.name -cne $expectedName -or
        [string]$asset.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or
        [string]::IsNullOrWhiteSpace([string]$asset.url)) {
        throw "Runtime manifest contains an invalid $TargetArchitecture asset."
    }
    return [pscustomobject]@{
        Version = [string]$manifest.version
        Name = [string]$asset.name
        Url = [string]$asset.url
        Sha256 = ([string]$asset.sha256).ToLowerInvariant()
        Architecture = $TargetArchitecture
    }
}

function Test-InstalledRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][object]$Asset
    )

    $exePath = Join-Path $InstallRoot 'bin\gh.exe'
    $metadataPath = Join-Path $InstallRoot '.swaw-runtime.json'
    if (-not [IO.File]::Exists($exePath) -or
        (Get-Item -LiteralPath $exePath).Length -le 0 -or
        -not [IO.File]::Exists($metadataPath)) {
        return $false
    }
    try {
        $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$metadata.schema -ne 'swaw.github-cli-install.v1' -or
            [string]$metadata.version -ne $Asset.Version -or
            [string]$metadata.architecture -ne $Asset.Architecture -or
            [string]$metadata.archiveSha256 -ne $Asset.Sha256 -or
            [string]$metadata.executableSha256 -notmatch '^[a-fA-F0-9]{64}$') {
            return $false
        }
        return (Get-Sha256 $exePath) -eq ([string]$metadata.executableSha256).ToLowerInvariant()
    } catch {
        return $false
    }
}

function Copy-Download {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if ([IO.File]::Exists($Source)) {
        [IO.File]::Copy((Get-FullPath $Source), $Destination, $false)
        return
    }
    $uri = $null
    if (-not [Uri]::TryCreate($Source, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https') {
        throw "Invalid runtime download source: $Source"
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $uri -OutFile $Destination -UseBasicParsing
}

function Get-CachedArchive {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$Asset
    )

    $cacheDir = Join-Path (Join-Path $Root 'cache\downloads') "$($Asset.Version)\$($Asset.Architecture)"
    [void][IO.Directory]::CreateDirectory($cacheDir)
    $archivePath = Join-Path $cacheDir $Asset.Name
    if ([IO.File]::Exists($archivePath) -and (Get-Sha256 $archivePath) -eq $Asset.Sha256) {
        return $archivePath
    }
    if ([IO.File]::Exists($archivePath)) {
        Remove-ControlledPath -Path $archivePath -Root $Root
    }

    $temporaryPath = Join-Path $cacheDir (".$($Asset.Name).$([Guid]::NewGuid().ToString('N')).tmp")
    try {
        Write-Host "[DL] $($Asset.Name)" -ForegroundColor DarkGray
        Copy-Download -Source $Asset.Url -Destination $temporaryPath
        if ((Get-Sha256 $temporaryPath) -ne $Asset.Sha256) {
            throw "SHA-256 verification failed for $($Asset.Name)."
        }
        [IO.File]::Move($temporaryPath, $archivePath)
        return $archivePath
    } finally {
        if ([IO.File]::Exists($temporaryPath)) {
            Remove-ControlledPath -Path $temporaryPath -Root $Root
        }
    }
}

function Expand-ZipSafely {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $destinationRoot = Get-FullPath $Destination
    [void][IO.Directory]::CreateDirectory($destinationRoot)
    $prefix = $destinationRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    [long]$totalBytes = 0
    $entryCount = 0
    try {
        foreach ($entry in $archive.Entries) {
            $entryCount++
            $totalBytes += $entry.Length
            if ($entryCount -gt 5000 -or $entry.Length -gt 512MB -or $totalBytes -gt 1GB) {
                throw 'GitHub CLI archive exceeds the extraction safety limits.'
            }
            $relative = $entry.FullName.Replace('/', [IO.Path]::DirectorySeparatorChar)
            if ([string]::IsNullOrWhiteSpace($relative)) {
                continue
            }
            $target = Get-FullPath (Join-Path $destinationRoot $relative)
            if (-not $target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Archive entry escapes the extraction directory: $($entry.FullName)"
            }
            if ($entry.FullName.EndsWith('/')) {
                [void][IO.Directory]::CreateDirectory($target)
                continue
            }
            [void][IO.Directory]::CreateDirectory((Split-Path $target -Parent))
            $input = $entry.Open()
            try {
                $output = [IO.File]::Open($target, 'CreateNew', 'Write', 'None')
                try {
                    $input.CopyTo($output)
                } finally {
                    $output.Dispose()
                }
            } finally {
                $input.Dispose()
            }
        }
    } finally {
        $archive.Dispose()
    }
}

function Publish-Runtime {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][object]$Asset
    )

    $runtimeRoot = Join-Path $Root 'runtime'
    [void][IO.Directory]::CreateDirectory($runtimeRoot)
    $stageRoot = Join-Path $runtimeRoot (".stage-$([Guid]::NewGuid().ToString('N'))")
    $extractRoot = Join-Path $stageRoot 'extract'
    $publishRoot = Join-Path $stageRoot 'publish'
    $backupPath = Join-Path $runtimeRoot (".backup-$([Guid]::NewGuid().ToString('N'))")
    $backedUp = $false

    try {
        Write-Host "[EXT] $($Asset.Name)" -ForegroundColor DarkGray
        Expand-ZipSafely -ArchivePath $ArchivePath -Destination $extractRoot
        $matches = @(Get-ChildItem -LiteralPath $extractRoot -Filter 'gh.exe' -File -Recurse |
            Where-Object { (Split-Path $_.DirectoryName -Leaf) -ieq 'bin' })
        if ($matches.Count -ne 1 -or $matches[0].Length -le 0) {
            throw 'GitHub CLI archive must contain exactly one bin\gh.exe.'
        }

        $publishBin = Join-Path $publishRoot 'bin'
        [void][IO.Directory]::CreateDirectory($publishBin)
        $publishedExe = Join-Path $publishBin 'gh.exe'
        Copy-Item -LiteralPath $matches[0].FullName -Destination $publishedExe
        $metadata = [ordered]@{
            schema = 'swaw.github-cli-install.v1'
            version = $Asset.Version
            architecture = $Asset.Architecture
            archiveSha256 = $Asset.Sha256
            executableSha256 = Get-Sha256 $publishedExe
        } | ConvertTo-Json
        [IO.File]::WriteAllText(
            (Join-Path $publishRoot '.swaw-runtime.json'),
            $metadata,
            (New-Object Text.UTF8Encoding($false))
        )
        if (-not (Test-InstalledRuntime -InstallRoot $publishRoot -Asset $Asset)) {
            throw 'Staged GitHub CLI runtime failed validation.'
        }

        if ([IO.Directory]::Exists($TargetPath)) {
            [IO.Directory]::Move($TargetPath, $backupPath)
            $backedUp = $true
        } elseif ([IO.File]::Exists($TargetPath)) {
            throw "Runtime target is unexpectedly a file: $TargetPath"
        }
        [IO.Directory]::Move($publishRoot, $TargetPath)
        if (-not (Test-InstalledRuntime -InstallRoot $TargetPath -Asset $Asset)) {
            throw 'Published GitHub CLI runtime failed validation.'
        }
        if ($backedUp) {
            try {
                Remove-ControlledPath -Path $backupPath -Root $Root
            } catch {
                Write-Warning "The replaced runtime backup could not be removed: $backupPath"
            }
            $backedUp = $false
        }
    } catch {
        if ($backedUp -and -not [IO.Directory]::Exists($TargetPath)) {
            [IO.Directory]::Move($backupPath, $TargetPath)
            $backedUp = $false
        }
        throw
    } finally {
        if ([IO.Directory]::Exists($stageRoot)) {
            Remove-ControlledPath -Path $stageRoot -Root $Root
        }
        if ($backedUp -and [IO.Directory]::Exists($backupPath)) {
            Write-Warning "Previous runtime backup was retained: $backupPath"
        }
    }
}

try {
    if ([string]::IsNullOrWhiteSpace($DataRoot)) {
        $DataRoot = Join-Path $PSScriptRoot '..\..\data\github-cli'
    }
    if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
        $ManifestPath = Join-Path $PSScriptRoot 'runtime-manifest.json'
    }
    $DataRoot = Get-FullPath $DataRoot
    $ManifestPath = Get-FullPath $ManifestPath
    $targetArchitecture = if ($Architecture) { $Architecture } else { Get-NativeArchitecture }
    $asset = Read-RuntimeManifest -Path $ManifestPath -TargetArchitecture $targetArchitecture
    $targetPath = Join-Path $DataRoot 'runtime\current'

    if ($Mode -eq 'Check') {
        if (-not (Test-InstalledRuntime -InstallRoot $targetPath -Asset $asset)) {
            throw "Portable GitHub CLI $($asset.Version) ($targetArchitecture) is missing or invalid."
        }
        if (-not $Quiet) {
            Write-Host "[OK] Portable runtime integrity: $($asset.Version) ($targetArchitecture)"
        }
        exit 0
    }

    [void][IO.Directory]::CreateDirectory($DataRoot)
    $lock = Enter-RuntimeLock -Path (Join-Path $DataRoot 'locks\runtime.lock')
    try {
        if (Test-InstalledRuntime -InstallRoot $targetPath -Asset $asset) {
            exit 0
        }
        Write-Host "[STEP] Setting up portable GitHub CLI $($asset.Version) ($targetArchitecture)..." -ForegroundColor Cyan
        $archivePath = Get-CachedArchive -Root $DataRoot -Asset $asset
        Publish-Runtime -Root $DataRoot -ArchivePath $archivePath -TargetPath $targetPath -Asset $asset
        Write-Host "[OK] Portable GitHub CLI is ready: $targetPath" -ForegroundColor Green
        exit 0
    } finally {
        $lock.Dispose()
    }
} catch {
    Write-Host "[ERROR] GitHub CLI runtime setup failed: $($_.Exception.Message)"
    exit 1
}
