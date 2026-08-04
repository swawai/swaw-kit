$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

if ($args.Count -ne 0) {
    throw 'The Swaw Kit Proj application build does not accept arguments.'
}

$AppRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$KernelRoot = [IO.Path]::GetFullPath((Join-Path $AppRoot '..'))
$ProjHome = [IO.Path]::GetFullPath((Join-Path $KernelRoot '..\..'))
$DeclaredProjHome = [string]$env:SWAWKIT_PROJ_HOME
if ([string]::IsNullOrWhiteSpace($DeclaredProjHome)) {
    throw 'Run this build through a Swaw Kit Proj project environment.'
}
$DeclaredProjHome = [IO.Path]::GetFullPath($DeclaredProjHome)
if (-not $DeclaredProjHome.Equals(
    $ProjHome,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw (
        "The active Proj home does not own this application: " +
        "$DeclaredProjHome"
    )
}

. (Join-Path $KernelRoot '_core\engine.ps1')
. (Join-Path $KernelRoot '.dev\setup\_modules\rust\runtime.ps1')

$ManifestPath = Join-Path $AppRoot 'Cargo.toml'
$TargetDirectory = Join-Path (
    $ProjHome
) 'data\proj_cache\cargo\swawkit-proj'
[string[]]$CargoArguments = @(
    'build',
    '--locked',
    '--release',
    '--manifest-path',
    $ManifestPath,
    '--target-dir',
    $TargetDirectory
)
$ExitCode = Invoke-ProjDevRustCommand `
    -ExecutableName 'cargo.exe' `
    -Arguments $CargoArguments
if ($ExitCode -ne 0) {
    exit ([int]$ExitCode)
}

$BuiltPath = Join-Path $TargetDirectory 'release\swawkit-proj.exe'
if (-not [IO.File]::Exists($BuiltPath)) {
    throw "Cargo reported success but the application is missing: $BuiltPath"
}
$BuiltItem = Get-Item -LiteralPath $BuiltPath
if ($BuiltItem.Length -le 0) {
    throw "Cargo produced an empty application: $BuiltPath"
}

$RuntimeDirectory = Join-Path $KernelRoot '_bin'
$RuntimePath = Join-Path $RuntimeDirectory 'swawkit-proj.exe'
[void][IO.Directory]::CreateDirectory($RuntimeDirectory)
$PublishPath = Join-Path $RuntimeDirectory (
    ".swawkit-proj.$([Guid]::NewGuid().ToString('N')).tmp"
)
$BackupPath = Join-Path $RuntimeDirectory (
    ".swawkit-proj.$([Guid]::NewGuid().ToString('N')).backup"
)
try {
    [IO.File]::Copy($BuiltPath, $PublishPath, $false)
    if ([IO.File]::Exists($RuntimePath)) {
        [IO.File]::Replace(
            $PublishPath,
            $RuntimePath,
            $BackupPath,
            $true
        )
    } else {
        [IO.File]::Move($PublishPath, $RuntimePath)
    }
} catch {
    throw (
        "Failed to publish the shared application '$RuntimePath'. " +
        'Exit the running Swaw Kit Host and retry. ' +
        $_.Exception.Message
    )
} finally {
    $CleanupPaths = @($PublishPath) + @(
        [IO.Directory]::GetFiles(
            $RuntimeDirectory,
            '.swawkit-proj.*.backup'
        )
    )
    foreach ($Path in $CleanupPaths) {
        if (-not [IO.File]::Exists($Path)) {
            continue
        }
        try {
            [IO.File]::Delete($Path)
        } catch {
            Write-Warning (
                "Build artifact remains in use and will be retried later: $Path"
            )
        }
    }
}

Write-Host $RuntimePath
