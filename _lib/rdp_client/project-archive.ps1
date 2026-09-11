Set-StrictMode -Version 2.0

function Import-RdpClientCompressionAssemblies {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
}

function Get-RdpClientArchiveSourceFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][int]$MaximumFiles,
        [Parameter(Mandatory = $true)][int64]$MaximumBytes,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $ResolvedRoot = [IO.Path]::GetFullPath($Root)
    $RootItem = Get-Item -LiteralPath $ResolvedRoot -Force
    if (($RootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label root cannot be a reparse point: $ResolvedRoot"
    }
    $Files = New-Object 'Collections.Generic.List[IO.FileInfo]'
    $Pending = New-Object 'Collections.Generic.Stack[string]'
    $Pending.Push($ResolvedRoot)
    $TotalBytes = [int64]0
    while ($Pending.Count -gt 0) {
        $Directory = $Pending.Pop()
        foreach ($Item in @(Get-ChildItem -LiteralPath $Directory -Force)) {
            if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Label cannot contain reparse points: $($Item.FullName)"
            }
            if ($Item -is [IO.DirectoryInfo]) {
                $Pending.Push($Item.FullName)
            } elseif ($Item -is [IO.FileInfo]) {
                $Files.Add($Item)
                if ($Files.Count -gt $MaximumFiles) {
                    throw "$Label contains more than $MaximumFiles files."
                }
                $TotalBytes += [int64]$Item.Length
                if ($TotalBytes -gt $MaximumBytes) {
                    throw "$Label exceeds the $MaximumBytes-byte limit."
                }
            } else {
                throw "$Label contains an unsupported filesystem object: $($Item.FullName)"
            }
        }
    }
    return $Files.ToArray()
}

function New-RdpClientProjectArchive {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [ValidateRange(1, 4096)][int]$MaximumFiles = 1024,
        [ValidateRange(1, 268435456)][int64]$MaximumBytes = 67108864
    )

    Import-RdpClientCompressionAssemblies
    $ResolvedRoot = [IO.Path]::GetFullPath($ProjectPath).TrimEnd('\', '/')
    $ResolvedArchive = [IO.Path]::GetFullPath($ArchivePath)
    if ([IO.File]::Exists($ResolvedArchive)) {
        throw "Project archive already exists: $ResolvedArchive"
    }
    $Files = @(Get-RdpClientArchiveSourceFiles `
        -Root $ResolvedRoot `
        -MaximumFiles $MaximumFiles `
        -MaximumBytes $MaximumBytes `
        -Label 'Project')

    [IO.Directory]::CreateDirectory(
        [IO.Path]::GetDirectoryName($ResolvedArchive)
    ) | Out-Null
    $FileStream = [IO.File]::Open(
        $ResolvedArchive,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None
    )
    try {
        $Archive = New-Object IO.Compression.ZipArchive(
            $FileStream,
            [IO.Compression.ZipArchiveMode]::Create,
            $false
        )
        try {
            foreach ($File in $Files) {
                $Relative = $File.FullName.Substring($ResolvedRoot.Length).
                    TrimStart('\', '/').Replace('\', '/')
                if ([string]::IsNullOrWhiteSpace($Relative) -or
                    $Relative.StartsWith('/') -or $Relative.Contains('../')) {
                    throw "Project file has an unsafe relative path: $($File.FullName)"
                }
                [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                    $Archive,
                    $File.FullName,
                    $Relative,
                    [IO.Compression.CompressionLevel]::Optimal
                ) | Out-Null
            }
        } finally {
            $Archive.Dispose()
        }
    } catch {
        $FileStream.Dispose()
        if ([IO.File]::Exists($ResolvedArchive)) {
            [IO.File]::Delete($ResolvedArchive)
        }
        throw
    } finally {
        $FileStream.Dispose()
    }
}

function Expand-RdpClientArtifactArchive {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [ValidateRange(1, 16384)][int]$MaximumFiles = 4096,
        [ValidateRange(1, 2147483648)][int64]$MaximumBytes = 1073741824
    )

    Import-RdpClientCompressionAssemblies
    $Destination = [IO.Path]::GetFullPath($DestinationPath).TrimEnd('\', '/')
    if ([IO.Directory]::Exists($Destination) -or [IO.File]::Exists($Destination)) {
        throw "Run output destination already exists: $Destination"
    }
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    $Succeeded = $false
    try {
        $Archive = [IO.Compression.ZipFile]::OpenRead(
            [IO.Path]::GetFullPath($ArchivePath)
        )
        try {
            if ($Archive.Entries.Count -gt $MaximumFiles) {
                throw "Run output contains more than $MaximumFiles files."
            }
            $TotalBytes = [int64]0
            foreach ($Entry in $Archive.Entries) {
                $TotalBytes += [int64]$Entry.Length
                if ($TotalBytes -gt $MaximumBytes) {
                    throw "Run output exceeds the $MaximumBytes-byte limit."
                }
                $Relative = $Entry.FullName.Replace('/', '\')
                if ([string]::IsNullOrWhiteSpace($Relative)) { continue }
                $Target = [IO.Path]::GetFullPath((Join-Path $Destination $Relative))
                if (-not ($Target + '\').StartsWith(
                    $Destination + '\',
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                    throw "Run output archive contains an unsafe path: $Relative"
                }
                if ([string]::IsNullOrEmpty($Entry.Name)) {
                    [IO.Directory]::CreateDirectory($Target) | Out-Null
                    continue
                }
                [IO.Directory]::CreateDirectory(
                    [IO.Path]::GetDirectoryName($Target)
                ) | Out-Null
                $Input = $Entry.Open()
                try {
                    $Output = [IO.File]::Open(
                        $Target,
                        [IO.FileMode]::CreateNew,
                        [IO.FileAccess]::Write,
                        [IO.FileShare]::None
                    )
                    try { $Input.CopyTo($Output) } finally { $Output.Dispose() }
                } finally { $Input.Dispose() }
            }
        } finally { $Archive.Dispose() }
        $Succeeded = $true
    } finally {
        if (-not $Succeeded -and [IO.Directory]::Exists($Destination)) {
            [IO.Directory]::Delete($Destination, $true)
        }
    }
}
