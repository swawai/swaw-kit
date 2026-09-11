Set-StrictMode -Version 2.0

function Get-RdpClientDataDirectory {
    return [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\data\rdp-client'))
}

function Get-RdpClientEntryDataDirectory {
    param([Parameter(Mandatory = $true)][string]$EntryFile)

    $ResolvedEntry = [IO.Path]::GetFullPath(
        [Environment]::ExpandEnvironmentVariables($EntryFile.Trim())
    )
    $EntryName = [IO.Path]::GetFileNameWithoutExtension($ResolvedEntry)
    if ([string]::IsNullOrWhiteSpace($EntryName)) {
        throw 'The RDP entry filename cannot identify a project directory.'
    }
    $SafeEntryName = $EntryName -replace '[^A-Za-z0-9._-]', '_'
    return Join-Path (Get-RdpClientDataDirectory) $SafeEntryName
}

function Get-RdpClientManagedProjectRoot {
    param([Parameter(Mandatory = $true)][string]$EntryFile)

    return Join-Path (Get-RdpClientEntryDataDirectory -EntryFile $EntryFile) 'projects'
}

function Get-RdpClientRunRoot {
    param([Parameter(Mandatory = $true)][string]$EntryFile)

    return Join-Path (Get-RdpClientEntryDataDirectory -EntryFile $EntryFile) 'runs'
}

function Test-RdpClientProjectName {
    param([Parameter(Mandatory = $true)][string]$Name)

    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or
        $Name.EndsWith('.') -or $Name.EndsWith(' ')) {
        return $false
    }
    $Stem = ($Name -split '\.')[0]
    return @(
        'CON', 'PRN', 'AUX', 'NUL',
        'COM1', 'COM2', 'COM3', 'COM4', 'COM5',
        'COM6', 'COM7', 'COM8', 'COM9',
        'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5',
        'LPT6', 'LPT7', 'LPT8', 'LPT9'
    ) -notcontains $Stem.ToUpperInvariant()
}

function Test-RdpClientAbsoluteProjectPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (
        $Path -match '^[A-Za-z]:[\\/]' -or
        $Path -match '^[\\/]{2}[^\\/]'
    )
}

function Resolve-RdpClientProject {
    param(
        [Parameter(Mandatory = $true)][string]$EntryFile,
        [Parameter(Mandatory = $true)][string]$Value,
        [switch]$RequireExisting
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw 'A project name or absolute path is required.'
    }
    $Expanded = [Environment]::ExpandEnvironmentVariables($Value.Trim())
    if (Test-RdpClientAbsoluteProjectPath -Path $Expanded) {
        $Path = [IO.Path]::GetFullPath($Expanded)
        $Name = Split-Path -Leaf $Path
        if ([string]::IsNullOrWhiteSpace($Name)) {
            throw 'A project path must identify a directory, not a drive root.'
        }
        $Kind = 'external'
    } elseif ([IO.Path]::IsPathRooted($Expanded) -or
        $Expanded -match '^[A-Za-z]:') {
        throw 'Project paths must be fully absolute (for example D:\work\project).'
    } else {
        if (-not (Test-RdpClientProjectName -Name $Expanded)) {
            throw (
                'Project must be either an absolute path or a safe name using ' +
                '1-64 letters, digits, dots, underscores, or hyphens.'
            )
        }
        $Name = $Expanded
        $Path = Join-Path (
            Get-RdpClientManagedProjectRoot -EntryFile $EntryFile
        ) $Name
        $Path = [IO.Path]::GetFullPath($Path)
        $Kind = 'managed'
    }

    $Exists = [IO.Directory]::Exists($Path)
    $FileExists = [IO.File]::Exists($Path)
    if ($RequireExisting -and -not $Exists) {
        throw "RDP execution project was not found: $Path"
    }
    $EntryPoint = Join-Path $Path 'run.ps1'
    if ($RequireExisting -and -not [IO.File]::Exists($EntryPoint)) {
        throw "RDP execution project has no run.ps1 entry point: $Path"
    }
    return [pscustomobject]@{
        Name       = $Name
        Path       = $Path
        Kind       = $Kind
        Exists     = $Exists
        FileExists = $FileExists
        EntryPoint = $EntryPoint
        Ready      = $Exists -and [IO.File]::Exists($EntryPoint)
    }
}

function New-RdpClientRunDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$EntryFile,
        [Parameter(Mandatory = $true)][string]$ProjectName
    )

    $SafeName = $ProjectName -replace '[^A-Za-z0-9._-]', '_'
    if ([string]::IsNullOrWhiteSpace($SafeName)) {
        $SafeName = 'project'
    }
    $RunId = (
        (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' +
        [Guid]::NewGuid().ToString('N').Substring(0, 8)
    )
    return Join-Path (Join-Path (
        Get-RdpClientRunRoot -EntryFile $EntryFile
    ) $SafeName) $RunId
}
