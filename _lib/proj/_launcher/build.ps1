[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CompilerPath,
    [Parameter(Mandatory = $true)][string]$LinkerPath,
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ProjectRoot = [string]$env:SWAWKIT_PROJ_DIR
$DataRoot = [string]$env:SWAWKIT_PROJ_DATA_ROOT
if ([string]::IsNullOrWhiteSpace($ProjectRoot) -or
    [string]::IsNullOrWhiteSpace($DataRoot)) {
    throw (
        'The launcher build requires the project runtime context. Invoke it ' +
        'through the project entry command.'
    )
}
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$DataRoot = [IO.Path]::GetFullPath($DataRoot)
$SourcePath = Join-Path $PSScriptRoot 'launcher.c'
$BuildRoot = Join-Path $DataRoot '_build\launcher'
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $ProjectRoot (
        'Favorites\template.proj1.exe'
    )
} elseif (-not [IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path $ProjectRoot $OutputPath
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)

foreach ($Tool in @(
    [pscustomobject]@{ Name = 'compiler'; Path = $CompilerPath },
    [pscustomobject]@{ Name = 'linker'; Path = $LinkerPath }
)) {
    if (-not [IO.Path]::IsPathRooted([string]$Tool.Path)) {
        throw "The injected $($Tool.Name) path must be absolute."
    }
    $Tool.Path = [IO.Path]::GetFullPath([string]$Tool.Path)
    if (-not [IO.File]::Exists([string]$Tool.Path)) {
        throw "The injected $($Tool.Name) does not exist: $($Tool.Path)"
    }
}
$CompilerPath = [IO.Path]::GetFullPath($CompilerPath)
$LinkerPath = [IO.Path]::GetFullPath($LinkerPath)

[void][IO.Directory]::CreateDirectory($BuildRoot)
[void][IO.Directory]::CreateDirectory(
    (Split-Path -Path $OutputPath -Parent)
)
$ObjectPath = Join-Path $BuildRoot 'launcher.obj'
$StagedPath = Join-Path $BuildRoot 'template.proj1.exe'

[string[]]$CompileArguments = @(
    '/nologo'
    '/Brepro'
    '/TC'
    '/c'
    '/O1'
    '/Os'
    '/Oi'
    '/Gy'
    '/Gw'
    '/Zl'
    "/Fo$ObjectPath"
    $SourcePath
)
& $CompilerPath @CompileArguments
if ($LASTEXITCODE -ne 0) {
    throw "cl.exe failed with exit code $LASTEXITCODE."
}

[string[]]$LinkArguments = @(
    '/nologo'
    '/Brepro'
    "/OUT:$StagedPath"
    '/ENTRY:launcher_entry'
    '/SUBSYSTEM:WINDOWS'
    '/MACHINE:X64'
    '/NODEFAULTLIB'
    '/INCREMENTAL:NO'
    '/OPT:REF'
    '/OPT:ICF'
    '/DEBUG:NONE'
    '/MANIFEST:NO'
    '/DYNAMICBASE'
    '/HIGHENTROPYVA'
    '/NXCOMPAT'
    $ObjectPath
    'kernel32.lib'
    'user32.lib'
)
& $LinkerPath @LinkArguments
if ($LASTEXITCODE -ne 0) {
    throw "link.exe failed with exit code $LASTEXITCODE."
}

$StagedItem = Get-Item -LiteralPath $StagedPath
if ($StagedItem.Length -le 0 -or $StagedItem.Length -gt 64KB) {
    throw (
        "Unexpected launcher size $($StagedItem.Length) bytes; expected a " +
        'non-empty thin executable no larger than 64 KiB.'
    )
}

$OutputParent = Split-Path -Path $OutputPath -Parent
$PublishPath = Join-Path $OutputParent (
    ".$([IO.Path]::GetFileName($OutputPath))." +
    "$([Guid]::NewGuid().ToString('N')).tmp"
)
$BackupPath = Join-Path $OutputParent (
    ".$([IO.Path]::GetFileName($OutputPath))." +
    "$([Guid]::NewGuid().ToString('N')).backup"
)
try {
    [IO.File]::Copy($StagedPath, $PublishPath, $false)
    if ([IO.File]::Exists($OutputPath)) {
        [IO.File]::Replace(
            $PublishPath,
            $OutputPath,
            $BackupPath,
            $true
        )
    } else {
        [IO.File]::Move($PublishPath, $OutputPath)
    }
} finally {
    if ([IO.File]::Exists($PublishPath)) {
        [IO.File]::Delete($PublishPath)
    }
    if ([IO.File]::Exists($BackupPath)) {
        [IO.File]::Delete($BackupPath)
    }
}

$OutputItem = Get-Item -LiteralPath $OutputPath
Write-Host (
    "[BUILT] $($OutputItem.FullName) ($($OutputItem.Length) bytes)"
) -ForegroundColor Green
$OutputItem | Select-Object FullName, Length, LastWriteTime
