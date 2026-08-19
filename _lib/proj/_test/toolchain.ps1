[CmdletBinding()]
param([string]$DevPath = '')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Assert-ProjShellToolchainTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw "Proj shell toolchain test failed: $Message"
    }
}

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
if ([string]::IsNullOrWhiteSpace($DevPath)) {
    $Current = [IO.File]::ReadAllText(
        (Join-Path $RepoRoot '_lib\proj\_bin\current'),
        [Text.Encoding]::UTF8
    ).TrimEnd("`r", "`n")
    $DevPath = Join-Path $RepoRoot (
        "_lib\proj\_bin\releases\$Current\swawkit-proj-dev.exe"
    )
}
$DevPath = [IO.Path]::GetFullPath($DevPath)
if (-not [IO.File]::Exists($DevPath)) {
    throw "Proj Dev candidate is missing: $DevPath"
}
. (Join-Path $RepoRoot '_lib\proj\_toolchain\_lib\runtime.ps1')
. (Join-Path $RepoRoot '_lib\proj\_toolchain\_lib\event.ps1')
. (Join-Path $RepoRoot '_lib\proj\_toolchain\_lib\artifact.ps1')

$TemporaryRoot = Join-Path $RepoRoot (
    "data\_test\swawkit-shell-toolchain-$([Guid]::NewGuid().ToString('N'))"
)
$SourceRoot = Join-Path $TemporaryRoot 'source'
$ControlledRoot = Join-Path $TemporaryRoot 'controlled'
$SourceArchive = Join-Path $TemporaryRoot 'fixture.zip'
$DownloadedArchive = Join-Path $ControlledRoot 'cache\fixture.zip'
$ExtractRoot = Join-Path $ControlledRoot 'extract'

try {
    [void][IO.Directory]::CreateDirectory($SourceRoot)
    [void][IO.Directory]::CreateDirectory(
        (Split-Path $DownloadedArchive -Parent)
    )
    [void][IO.Directory]::CreateDirectory($ExtractRoot)
    [IO.File]::WriteAllText(
        (Join-Path $SourceRoot 'fixture.txt'),
        'shell-toolchain',
        [Text.UTF8Encoding]::new($false)
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $SourceRoot,
        $SourceArchive,
        [IO.Compression.CompressionLevel]::Optimal,
        $false
    )

    Invoke-ProjDevDownload `
        -Source $SourceArchive `
        -Destination $DownloadedArchive `
        -ControlledRoot $ControlledRoot
    Assert-ProjShellToolchainTest `
        -Condition (Test-ProjDevZipArchive -Path $DownloadedArchive) `
        -Message 'the native shell ZIP validator rejected a valid archive'
    Expand-ProjDevZipSafely `
        -ArchivePath $DownloadedArchive `
        -Destination $ExtractRoot `
        -ControlledRoot $ControlledRoot
    Assert-ProjShellToolchainTest `
        -Condition ([IO.File]::ReadAllText(
            (Join-Path $ExtractRoot 'fixture.txt'),
            [Text.Encoding]::UTF8
        ) -ceq 'shell-toolchain') `
        -Message 'the native shell path did not preserve the payload'

    $PreviousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $LegacyOutput = @(& $DevPath 'download-v1' 2>&1)
        $LegacyExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $PreviousPreference
    }
    Assert-ProjShellToolchainTest `
        -Condition (
            $LegacyExitCode -ne 0 -and
            [string]::Join("`n", [string[]]$LegacyOutput).Contains(
                'expected: swawkit-proj-dev.exe command-v1'
            )
        ) `
        -Message 'the Dev runtime accepted the removed generic Toolchain transport'
} finally {
    if ([IO.Directory]::Exists($TemporaryRoot)) {
        [IO.Directory]::Delete($TemporaryRoot, $true)
    }
}

Write-Host '[PASS] Proj Stage-0 shell toolchain boundary' -ForegroundColor Green
$global:LASTEXITCODE = 0
