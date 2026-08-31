[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$runtimeScript = Join-Path $repoRoot '_lib\github_cli_kit\runtime.ps1'
$tempRoot = Join-Path (Join-Path $repoRoot 'temp_workspace') ("gh-runtime-$([Guid]::NewGuid().ToString('N'))")
$engine = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-Sha256 {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return -join @($algorithm.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') })
    } finally {
        $algorithm.Dispose()
        $stream.Dispose()
    }
}

function Invoke-Runtime {
    param(
        [string]$DataRoot,
        [string]$ManifestPath,
        [string]$Mode = 'Ensure',
        [int]$ExpectedExitCode = 0
    )
    $output = (& $engine -NoLogo -NoProfile -ExecutionPolicy Bypass -File $runtimeScript `
        -Mode $Mode -DataRoot $DataRoot -ManifestPath $ManifestPath -Architecture amd64 2>&1 | Out-String)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne $ExpectedExitCode) {
        throw "Runtime returned $exitCode; expected $ExpectedExitCode.`n$output"
    }
    return $output
}

function Write-FixtureManifest {
    param(
        [string]$Path,
        [string]$ArchivePath,
        [string]$Sha256,
        [string]$AssetName = 'gh_9.9.9_windows_amd64.zip'
    )
    $manifest = [ordered]@{
        schema = 'swaw.github-cli-runtime.v1'
        version = '9.9.9'
        assets = [ordered]@{
            amd64 = [ordered]@{
                name = $AssetName
                url = $ArchivePath
                sha256 = $Sha256
            }
        }
    } | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($Path, $manifest, [Text.UTF8Encoding]::new($false))
}

try {
    [void][IO.Directory]::CreateDirectory($tempRoot)
    $archiveInput = Join-Path $tempRoot 'archive-input'
    $archiveBin = Join-Path $archiveInput 'gh_9.9.9_windows_amd64\bin'
    [void][IO.Directory]::CreateDirectory($archiveBin)
    [IO.File]::WriteAllBytes((Join-Path $archiveBin 'gh.exe'), [byte[]](1..128))

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archivePath = Join-Path $tempRoot 'gh_9.9.9_windows_amd64.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($archiveInput, $archivePath)
    $sha256 = Get-Sha256 $archivePath
    $manifestPath = Join-Path $tempRoot 'manifest.json'
    Write-FixtureManifest -Path $manifestPath -ArchivePath $archivePath -Sha256 $sha256

    $dataRoot = Join-Path $tempRoot 'data-good'
    $first = Invoke-Runtime -DataRoot $dataRoot -ManifestPath $manifestPath
    Assert-True ($first.Contains('Portable GitHub CLI is ready')) 'First ensure should publish the runtime.'
    $installedExe = Join-Path $dataRoot 'runtime\current\bin\gh.exe'
    Assert-True ([IO.File]::Exists($installedExe)) 'Portable gh.exe should be published.'

    $second = Invoke-Runtime -DataRoot $dataRoot -ManifestPath $manifestPath
    Assert-True ([string]::IsNullOrWhiteSpace($second)) 'Second ensure should be idempotent and quiet.'
    $check = Invoke-Runtime -DataRoot $dataRoot -ManifestPath $manifestPath -Mode Check
    Assert-True ($check.Contains('Portable runtime integrity')) 'Check should validate metadata and executable hash.'

    [IO.File]::AppendAllText($installedExe, 'tampered')
    $invalid = Invoke-Runtime -DataRoot $dataRoot -ManifestPath $manifestPath -Mode Check -ExpectedExitCode 1
    Assert-True ($invalid.Contains('missing or invalid')) 'Check should detect executable tampering.'
    [void](Invoke-Runtime -DataRoot $dataRoot -ManifestPath $manifestPath)
    [void](Invoke-Runtime -DataRoot $dataRoot -ManifestPath $manifestPath -Mode Check)

    $badManifest = Join-Path $tempRoot 'manifest-bad-sha.json'
    Write-FixtureManifest -Path $badManifest -ArchivePath $archivePath -Sha256 ('0' * 64)
    $badData = Join-Path $tempRoot 'data-bad'
    $mismatch = Invoke-Runtime -DataRoot $badData -ManifestPath $badManifest -ExpectedExitCode 1
    Assert-True ($mismatch.Contains('SHA-256 verification failed')) 'Wrong checksum should fail closed.'
    Assert-True (-not [IO.Directory]::Exists((Join-Path $badData 'runtime\current'))) 'Failed setup must not publish a runtime.'

    $wrongNameManifest = Join-Path $tempRoot 'manifest-wrong-name.json'
    Write-FixtureManifest `
        -Path $wrongNameManifest `
        -ArchivePath $archivePath `
        -Sha256 $sha256 `
        -AssetName 'gh_8.8.8_windows_amd64.zip'
    $wrongNameData = Join-Path $tempRoot 'data-wrong-name'
    $wrongName = Invoke-Runtime `
        -DataRoot $wrongNameData `
        -ManifestPath $wrongNameManifest `
        -ExpectedExitCode 1
    Assert-True ($wrongName.Contains('invalid amd64 asset')) 'Asset name must match the manifest version.'
    Assert-True (-not [IO.Directory]::Exists((Join-Path $wrongNameData 'runtime\current'))) 'Inconsistent manifests must not publish a runtime.'

    Write-Host 'github cli portable runtime smoke: PASS' -ForegroundColor Green
} finally {
    if ([IO.Directory]::Exists($tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
