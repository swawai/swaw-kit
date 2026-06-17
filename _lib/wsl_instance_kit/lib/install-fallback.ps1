$script:WslDistributionInfoPath = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $PSCommandPath) "..\DistributionInfo.json"))

function Get-WslDownloadDir {
    return (Join-Path $script:Config.EntryDir "data\wsl.downloads")
}

function Get-WslDownloadTempRoot {
    return [System.IO.Path]::GetFullPath((Join-Path ([System.IO.Path]::GetTempPath()) "wsl_instance_kit"))
}

function New-WslDownloadTempPath {
    param([string]$FileName)

    $tempRoot = Get-WslDownloadTempRoot
    $tempDir = Join-Path $tempRoot ([guid]::NewGuid().ToString("N"))
    Ensure-Directory $tempDir

    return [pscustomobject]@{
        Directory = $tempDir
        Path = Join-Path $tempDir $FileName
    }
}

function Remove-WslDownloadTemp {
    param([AllowNull()] [pscustomobject]$Temp)

    if ($null -eq $Temp) {
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($Temp.Path) -and (Test-Path -LiteralPath $Temp.Path -PathType Leaf)) {
        Remove-Item -LiteralPath $Temp.Path -Force -ErrorAction SilentlyContinue
    }

    if ([string]::IsNullOrWhiteSpace($Temp.Directory) -or -not (Test-Path -LiteralPath $Temp.Directory -PathType Container)) {
        return
    }

    $tempRoot = (Get-WslDownloadTempRoot).TrimEnd("\") + "\"
    $tempDir = [System.IO.Path]::GetFullPath($Temp.Directory)
    if (-not $tempDir.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Warn "Refusing to clean unexpected temp directory: $tempDir"
        return
    }

    Remove-Item -LiteralPath $tempDir -Force -Recurse -ErrorAction SilentlyContinue
}

function Read-WslDistributionInfo {
    $path = $script:WslDistributionInfoPath
    try {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Write-Fail "DistributionInfo JSON not found: $path"
            return $null
        }

        return ([System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
    } catch {
        Write-Fail "Failed to read DistributionInfo: $path"
        Write-Fail $_.Exception.Message
        return $null
    }
}

function Get-WslInstallArchitectureKey {
    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    switch ($arch) {
        { $_ -in @("x64", "x86_64", "amd64") } { return "Amd64Url" }
        { $_ -in @("arm64", "aarch64") } { return "Arm64Url" }
        default {
            Write-Fail "Unsupported Windows architecture for fallback install: $arch"
            return ""
        }
    }
}

function Find-WslModernDistribution {
    param(
        [pscustomobject]$DistributionInfo,
        [string]$Name
    )

    if ($null -eq $DistributionInfo.ModernDistributions) {
        return $null
    }

    foreach ($group in @($DistributionInfo.ModernDistributions.PSObject.Properties)) {
        foreach ($item in @($group.Value)) {
            if ($item.Name -ieq $Name -or $item.FriendlyName -ieq $Name) {
                return $item
            }
        }
    }

    return $null
}

function Find-WslLegacyDistribution {
    param(
        [pscustomobject]$DistributionInfo,
        [string]$Name
    )

    foreach ($item in @($DistributionInfo.Distributions)) {
        if ($item.Name -ieq $Name -or $item.FriendlyName -ieq $Name) {
            return $item
        }
    }

    return $null
}

function Get-WslFallbackDownload {
    param([string]$DistroName)

    $info = Read-WslDistributionInfo
    if ($null -eq $info) {
        return $null
    }

    $modernKey = Get-WslInstallArchitectureKey
    if ([string]::IsNullOrWhiteSpace($modernKey)) {
        return $null
    }

    $modern = Find-WslModernDistribution $info $DistroName
    if ($null -ne $modern) {
        $urlInfo = $modern.$modernKey
        if ($null -eq $urlInfo -or [string]::IsNullOrWhiteSpace($urlInfo.Url)) {
            Write-Fail "No $modernKey download URL for distribution: $DistroName"
            return $null
        }

        return [pscustomobject]@{
            Name = $modern.Name
            FriendlyName = $modern.FriendlyName
            Url = $urlInfo.Url
            Sha256 = $urlInfo.Sha256
        }
    }

    $legacy = Find-WslLegacyDistribution $info $DistroName
    if ($null -eq $legacy) {
        Write-Fail "Distribution not found in DistributionInfo: $DistroName"
        return $null
    }

    $legacyUrl = if ($modernKey -eq "Arm64Url") { $legacy.Arm64PackageUrl } else { $legacy.Amd64PackageUrl }
    if ([string]::IsNullOrWhiteSpace($legacyUrl)) {
        Write-Fail "No package URL for distribution: $DistroName"
        return $null
    }

    return [pscustomobject]@{
        Name = $legacy.Name
        FriendlyName = $legacy.FriendlyName
        Url = $legacyUrl
        Sha256 = ""
    }
}

function Get-SafeFileName {
    param([string]$Value)

    $safe = $Value
    foreach ($char in [System.IO.Path]::GetInvalidFileNameChars()) {
        $safe = $safe.Replace([string]$char, "_")
    }

    return $safe
}

function Get-FileNameFromUrl {
    param([string]$Url)

    try {
        $uri = [Uri]$Url
        $name = [System.IO.Path]::GetFileName($uri.LocalPath)
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            return (Get-SafeFileName $name)
        }
    } catch {
    }

    return "wsl-image"
}

function Normalize-Sha256Text {
    param([AllowNull()] [string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $result = $Value.Trim().ToLowerInvariant()
    if ($result.StartsWith("0x")) {
        $result = $result.Substring(2)
    }

    return $result
}

function Get-FileSha256 {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ""
    }

    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $sha256 = [System.Security.Cryptography.SHA256]::Create()
            try {
                $hashBytes = $sha256.ComputeHash($stream)
                $actual = ([System.BitConverter]::ToString($hashBytes) -replace "-", "").ToLowerInvariant()
            } finally {
                $sha256.Dispose()
            }
        } finally {
            $stream.Dispose()
        }
    } catch {
        return ""
    }

    return $actual
}

function Test-FileSha256 {
    param(
        [string]$Path,
        [string]$Expected
    )

    $expectedHash = Normalize-Sha256Text $Expected
    if ([string]::IsNullOrWhiteSpace($expectedHash)) {
        return $true
    }

    $actual = Get-FileSha256 $Path
    if ([string]::IsNullOrWhiteSpace($actual)) {
        return $false
    }

    return ($actual -eq $expectedHash)
}

function Get-WslImageHashPath {
    param([string]$ImagePath)

    return "$ImagePath.sha256"
}

function Read-WslImageHash {
    param([string]$ImagePath)

    $hashPath = Get-WslImageHashPath $ImagePath
    if (-not (Test-Path -LiteralPath $hashPath -PathType Leaf)) {
        return ""
    }

    try {
        $text = [System.IO.File]::ReadAllText($hashPath, [System.Text.Encoding]::UTF8)
    } catch {
        return ""
    }

    if ($text -match "(?i)\b([0-9a-f]{64})\b") {
        return $Matches[1].ToLowerInvariant()
    }

    return ""
}

function Write-WslImageHash {
    param([string]$ImagePath)

    $hash = Get-FileSha256 $ImagePath
    if ([string]::IsNullOrWhiteSpace($hash)) {
        Write-Warn "Unable to compute image SHA256 sidecar: $ImagePath"
        return $false
    }

    $hashPath = Get-WslImageHashPath $ImagePath
    $fileName = [System.IO.Path]::GetFileName($ImagePath)
    try {
        [System.IO.File]::WriteAllText($hashPath, "$hash  $fileName`r`n", [System.Text.UTF8Encoding]::new($false))
        return $true
    } catch {
        Write-Warn "Failed to write image SHA256 sidecar: $hashPath"
        Write-Warn $_.Exception.Message
        return $false
    }
}

function Remove-WslFallbackImageCache {
    param([string]$ImagePath)

    $hashPath = Get-WslImageHashPath $ImagePath
    if (Test-Path -LiteralPath $ImagePath -PathType Leaf) {
        Remove-Item -LiteralPath $ImagePath -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path -LiteralPath $hashPath -PathType Leaf) {
        Remove-Item -LiteralPath $hashPath -Force -ErrorAction SilentlyContinue
    }
}

function Test-WslFallbackImageCache {
    param(
        [pscustomobject]$Download,
        [string]$ImagePath
    )

    if (-not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) {
        return $false
    }

    $actual = Get-FileSha256 $ImagePath
    if ([string]::IsNullOrWhiteSpace($actual)) {
        Write-Warn "Unable to read cached fallback image; downloading again."
        return $false
    }

    $hashPath = Get-WslImageHashPath $ImagePath
    $hasSidecar = Test-Path -LiteralPath $hashPath -PathType Leaf
    $stored = Read-WslImageHash $ImagePath
    if ($hasSidecar -and [string]::IsNullOrWhiteSpace($stored)) {
        Write-Warn "Cached image hash sidecar is invalid; downloading again."
        return $false
    }

    if (-not [string]::IsNullOrWhiteSpace($stored) -and $actual -ne $stored) {
        Write-Warn "Cached image hash sidecar does not match the image; downloading again."
        return $false
    }

    $expected = Normalize-Sha256Text $Download.Sha256
    if (-not [string]::IsNullOrWhiteSpace($expected) -and $actual -ne $expected) {
        Write-Warn "Cached image hash does not match DistributionInfo; downloading again."
        return $false
    }

    if ((-not $hasSidecar) -and [string]::IsNullOrWhiteSpace($expected)) {
        Write-Warn "Cached image has no hash sidecar; downloading again."
        return $false
    }

    return $true
}

function Save-WslFallbackImage {
    param(
        [pscustomobject]$Download,
        [string]$Destination
    )

    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        if (Test-WslFallbackImageCache $Download $Destination) {
            Write-Host "Using cached fallback image: $Destination"
            return $true
        }

        Remove-WslFallbackImageCache $Destination
    }

    Ensure-Directory (Split-Path -Parent $Destination)
    Write-Host "Downloading fallback image:"
    Write-Host "  $($Download.Url)"
    Write-Host "  -> $Destination"

    $temp = New-WslDownloadTempPath ([System.IO.Path]::GetFileName($Destination))
    $tempPath = $temp.Path
    try {
        $bits = Get-Command -Name "Start-BitsTransfer" -ErrorAction SilentlyContinue
        if ($bits) {
            Start-BitsTransfer -Source $Download.Url -Destination $tempPath -Description "Downloading WSL fallback image"
        } else {
            Invoke-WebRequest -Uri $Download.Url -OutFile $tempPath -UseBasicParsing
        }
    } catch {
        Write-Fail "Failed to download fallback image."
        Write-Fail $_.Exception.Message
        Remove-WslDownloadTemp $temp
        return $false
    }

    try {
        if (-not (Test-FileSha256 $tempPath $Download.Sha256)) {
            Write-Fail "Downloaded image SHA256 does not match DistributionInfo."
            Remove-WslDownloadTemp $temp
            return $false
        }

        Move-Item -LiteralPath $tempPath -Destination $Destination -Force
    } catch {
        Write-Fail "Failed to verify or move fallback image."
        Write-Fail $_.Exception.Message
        Remove-WslDownloadTemp $temp
        return $false
    }

    Remove-WslDownloadTemp $temp
    return $true
}

function Test-WslPackagedImage {
    param([string]$Path)

    $extension = [System.IO.Path]::GetExtension($Path)
    return ($extension -in @(".appx", ".msix"))
}

function Get-WslPackagedImageDefaultInstallPath {
    param([string]$PackagePath)

    return "$PackagePath.install.tar.gz"
}

function Find-WslPackagedRootfsEntryName {
    param([string]$PackagePath)

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $archive = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
        try {
            $entries = @($archive.Entries | Where-Object {
                $_.Length -gt 0 -and $_.FullName -match '(^|/)(install|rootfs)\.tar(\.(gz|xz))?$'
            })

            $entry = @($entries | Sort-Object FullName | Select-Object -First 1)[0]
            if ($null -ne $entry) {
                return $entry.FullName
            }
        } finally {
            $archive.Dispose()
        }
    } catch {
        Write-Fail "Failed to inspect packaged WSL image: $PackagePath"
        Write-Fail $_.Exception.Message
        return $null
    }

    Write-Fail "No install/rootfs tar archive found inside packaged WSL image: $PackagePath"
    return $null
}

function Expand-WslPackagedImage {
    param([string]$PackagePath)

    $entryNameInPackage = Find-WslPackagedRootfsEntryName $PackagePath
    if ([string]::IsNullOrWhiteSpace($entryNameInPackage)) {
        return ""
    }

    $entryName = Get-SafeFileName ([System.IO.Path]::GetFileName($entryNameInPackage))
    $destination = "$PackagePath.$entryName"
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        if ((Get-Item -LiteralPath $destination).LastWriteTimeUtc -ge (Get-Item -LiteralPath $PackagePath).LastWriteTimeUtc -and
            -not [string]::IsNullOrWhiteSpace((Get-FileSha256 $destination))) {
            Write-Host "Using cached extracted fallback image: $destination"
            return $destination
        }

        Remove-WslFallbackImageCache $destination
    }

    Write-Host "Extracting packaged fallback image:"
    Write-Host "  $entryNameInPackage"
    Write-Host "  -> $destination"

    $temp = New-WslDownloadTempPath ([System.IO.Path]::GetFileName($destination))
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $archive = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
        try {
            $entry = $archive.GetEntry($entryNameInPackage)
            if ($null -eq $entry) {
                Write-Fail "Packaged WSL image entry disappeared: $entryNameInPackage"
                Remove-WslDownloadTemp $temp
                return ""
            }

            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $temp.Path, $true)
        } finally {
            $archive.Dispose()
        }
        Move-Item -LiteralPath $temp.Path -Destination $destination -Force
        [void](Write-WslImageHash $destination)
    } catch {
        Write-Fail "Failed to extract packaged fallback image."
        Write-Fail $_.Exception.Message
        Remove-WslDownloadTemp $temp
        return ""
    }

    Remove-WslDownloadTemp $temp
    return $destination
}

function Resolve-WslFallbackInstallImage {
    param([string]$ImagePath)

    if (-not (Test-WslPackagedImage $ImagePath)) {
        return $ImagePath
    }

    return (Expand-WslPackagedImage $ImagePath)
}

function Install-WslResourceFallback {
    param(
        [string[]]$NativeExtra,
        [switch]$DryRun
    )

    $source = Resolve-WslSource $script:Config.Source
    $installDir = Resolve-EntryPath $script:Config.InstallDir

    if ([string]::IsNullOrWhiteSpace($source)) {
        Write-Fail "WSL_source is empty. Set it to a .tar path or an online distro name."
        return 1
    }

    if ([string]::IsNullOrWhiteSpace($installDir)) {
        Write-Fail "WSL_install_dir is empty."
        return 1
    }

    if (Test-ArchiveSource $source) {
        Write-Warn "WSL_source is already an archive path; fallback is the same as native import."
        $nativeArgs = @("--import", $script:Config.Name, $installDir, $source)
        if (-not [string]::IsNullOrWhiteSpace($script:Config.Version)) {
            $nativeArgs += @("--version", $script:Config.Version)
        }
        $nativeArgs += @($NativeExtra)

        if ($DryRun) {
            Show-NativeCommand "wsl.exe" $nativeArgs
            [void](Ensure-WslConfiguredUser -DryRun -AllowEmpty)
            return 0
        }

        Ensure-Directory $installDir
        $exitCode = Invoke-External "wsl.exe" $nativeArgs
        if ($exitCode -ne 0) {
            return $exitCode
        }

        $userExit = Ensure-WslConfiguredUser -AllowEmpty
        if ($userExit -ne 0) {
            return $userExit
        }

        [void](Write-WslImageHash $source)
        return 0
    }

    $download = Get-WslFallbackDownload $source
    if ($null -eq $download) {
        return 1
    }

    $cacheDir = Get-WslDownloadDir
    $fileName = "{0}_{1}" -f (Get-SafeFileName $download.Name), (Get-FileNameFromUrl $download.Url)
    $imagePath = Join-Path $cacheDir $fileName
    $dryRunInstallPath = if (Test-WslPackagedImage $imagePath) { Get-WslPackagedImageDefaultInstallPath $imagePath } else { $imagePath }
    $parentDir = Split-Path -Parent $installDir

    $nativeArgs = @("--install", "--from-file", $dryRunInstallPath, "--name", $script:Config.Name, "--location", $installDir, "--no-launch")
    if (-not [string]::IsNullOrWhiteSpace($script:Config.Version)) {
        $nativeArgs += @("--version", $script:Config.Version)
    }
    $nativeArgs += @($NativeExtra)

    if ($DryRun) {
        Write-Host "DistributionInfo: $script:WslDistributionInfoPath"
        Write-Host "Fallback image URL: $($download.Url)"
        if (-not [string]::IsNullOrWhiteSpace($download.Sha256)) {
            Write-Host "Fallback image SHA256: $(Normalize-Sha256Text $download.Sha256)"
        }
        Write-Host "Download path: $imagePath"
        if ($dryRunInstallPath -ne $imagePath) {
            Write-Host "Install path: $dryRunInstallPath"
        }
        Show-NativeCommand "wsl.exe" $nativeArgs
        [void](Ensure-WslConfiguredUser -DryRun -AllowEmpty)
        return 0
    }

    if (-not (Save-WslFallbackImage $download $imagePath)) {
        return 1
    }

    $installImagePath = Resolve-WslFallbackInstallImage $imagePath
    if ([string]::IsNullOrWhiteSpace($installImagePath)) {
        return 1
    }

    $nativeArgs = @("--install", "--from-file", $installImagePath, "--name", $script:Config.Name, "--location", $installDir, "--no-launch")
    if (-not [string]::IsNullOrWhiteSpace($script:Config.Version)) {
        $nativeArgs += @("--version", $script:Config.Version)
    }
    $nativeArgs += @($NativeExtra)

    Ensure-Directory $parentDir
    $exit = Invoke-External "wsl.exe" $nativeArgs
    if ($exit -ne 0) {
        return $exit
    }

    $userExit = Ensure-WslConfiguredUser -AllowEmpty
    if ($userExit -ne 0) {
        return $userExit
    }

    [void](Write-WslImageHash $imagePath)
    if ($installImagePath -ne $imagePath) {
        [void](Write-WslImageHash $installImagePath)
    }
    return 0
}
