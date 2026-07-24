Set-StrictMode -Version 2.0

$script:XvenvKitRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:XvenvActiveEnvironmentMarkers = @(
    'XVENV_PROJECT_ROOT',
    'XVENV_PROJECT_HOME',
    'XVENV_HOME'
)

function Assert-XvenvNotActive {
    foreach ($Name in [string[]]$script:XvenvActiveEnvironmentMarkers) {
        if ($null -ne [Environment]::GetEnvironmentVariable(
            $Name,
            [EnvironmentVariableTarget]::Process
        )) {
            throw "xvenv is already active. Exit the current xvenv terminal before running this command again (marker: $Name)."
        }
    }
}

function Get-XvenvFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $FullPath = [IO.Path]::GetFullPath($Path)
    $PathRoot = [IO.Path]::GetPathRoot($FullPath)
    if ($FullPath.Length -gt $PathRoot.Length) {
        $FullPath = $FullPath.TrimEnd([char[]]@(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar
        ))
    }
    return $FullPath
}

function Get-XvenvCanonicalPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-XvenvFullPath $Path).ToUpperInvariant()
}

function Get-XvenvSha256 {
    param([Parameter(Mandatory = $true)][string]$Value)

    $Algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $Bytes = [Text.Encoding]::UTF8.GetBytes($Value)
        return ([BitConverter]::ToString($Algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $Algorithm.Dispose()
    }
}

function Get-XvenvSafeSegment {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') {
        throw "Invalid $Description '$Value'. Use only A-Z, a-z, 0-9, dot, underscore, plus, and hyphen."
    }
    return $Value
}

function Resolve-XvenvProjectRoot {
    param([Parameter(Mandatory = $true)][string]$WorkingDirectory)

    $Start = Get-XvenvFullPath $WorkingDirectory
    if (-not [IO.Directory]::Exists($Start)) {
        throw "Working directory does not exist: $Start"
    }

    $Current = $Start
    while ($true) {
        $GitMarker = Join-Path $Current '.git'
        if ([IO.Directory]::Exists($GitMarker) -or [IO.File]::Exists($GitMarker)) {
            return $Current
        }

        $Parent = [IO.Directory]::GetParent($Current)
        if ($null -eq $Parent) {
            return $Start
        }
        $Current = $Parent.FullName
    }
}

function Get-XvenvProjectId {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $CanonicalRoot = Get-XvenvCanonicalPath $ProjectRoot
    $Hash = (Get-XvenvSha256 $CanonicalRoot).Substring(0, 16)
    $Leaf = Split-Path (Get-XvenvFullPath $ProjectRoot) -Leaf
    if ([string]::IsNullOrWhiteSpace($Leaf)) {
        $Leaf = 'project'
    }
    $Slug = [regex]::Replace($Leaf, '[^A-Za-z0-9._-]', '_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($Slug)) {
        $Slug = 'project'
    }
    if ($Slug.Length -gt 48) {
        $Slug = $Slug.Substring(0, 48).TrimEnd('_', '.', '-')
    }
    if ([string]::IsNullOrWhiteSpace($Slug)) {
        $Slug = 'project'
    }
    return "$Slug--$Hash"
}

function New-XvenvContext {
    param(
        [string]$WorkingDirectory = (Get-Location).Path,
        [AllowNull()][string]$ProjectRoot = $null,
        [AllowNull()][string]$ToolboxRoot = $null,
        [AllowNull()][string]$DataRoot = $null,
        [AllowNull()][object]$Catalog = $null,
        [AllowNull()][scriptblock]$RunExternal = $null,
        [AllowNull()][scriptblock]$LaunchTerminal = $null
    )

    $InvocationDirectory = Get-XvenvFullPath $WorkingDirectory
    $ResolvedProjectRoot = if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
        Resolve-XvenvProjectRoot $InvocationDirectory
    } else {
        Get-XvenvFullPath $ProjectRoot
    }

    if ([string]::IsNullOrWhiteSpace($ToolboxRoot)) {
        $ToolboxRoot = Get-XvenvFullPath (Join-Path $script:XvenvKitRoot '..\..')
    } else {
        $ToolboxRoot = Get-XvenvFullPath $ToolboxRoot
    }

    if ([string]::IsNullOrWhiteSpace($DataRoot)) {
        $DataRoot = Join-Path $ToolboxRoot 'data\xvenv'
    }
    $DataRoot = Get-XvenvFullPath $DataRoot

    if ($null -eq $Catalog) {
        $Catalog = Import-XvenvModuleCatalog (Join-Path $script:XvenvKitRoot 'modules')
    }

    $ProjectId = Get-XvenvProjectId $ResolvedProjectRoot
    $ProjectDataRoot = Join-Path (Join-Path $DataRoot 'projects') $ProjectId

    return [pscustomobject]@{
        ToolboxRoot = $ToolboxRoot
        DataRoot = $DataRoot
        ProjectRoot = $ResolvedProjectRoot
        CanonicalProjectRoot = Get-XvenvCanonicalPath $ResolvedProjectRoot
        ProjectId = $ProjectId
        ProjectDataRoot = $ProjectDataRoot
        EnvCmdPath = Join-Path $ProjectDataRoot 'env.cmd'
        EnvPs1Path = Join-Path $ProjectDataRoot 'env.ps1'
        InvocationDirectory = $InvocationDirectory
        Catalog = $Catalog
        RunExternal = $RunExternal
        LaunchTerminal = $LaunchTerminal
    }
}

function ConvertTo-XvenvJsonText {
    param([Parameter(Mandatory = $true)][object]$Value)

    $Json = $Value | ConvertTo-Json -Depth 10
    $Json = $Json.Replace("`r`n", "`n").Replace("`r", "`n").Replace("`n", "`r`n")
    return "$Json`r`n"
}

function Write-XvenvTextAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content,
        [Text.Encoding]$Encoding = [Text.UTF8Encoding]::new($false)
    )

    $FullPath = Get-XvenvFullPath $Path
    $Parent = Split-Path $FullPath -Parent
    [void][IO.Directory]::CreateDirectory($Parent)
    $TemporaryPath = Join-Path $Parent (".$([IO.Path]::GetFileName($FullPath)).$([Guid]::NewGuid().ToString('N')).tmp")
    $BackupPath = Join-Path $Parent (".$([IO.Path]::GetFileName($FullPath)).$([Guid]::NewGuid().ToString('N')).bak")

    try {
        [IO.File]::WriteAllText($TemporaryPath, $Content, $Encoding)
        if ([IO.File]::Exists($FullPath)) {
            [IO.File]::Replace($TemporaryPath, $FullPath, $BackupPath)
        } else {
            [IO.File]::Move($TemporaryPath, $FullPath)
        }
    } finally {
        if ([IO.File]::Exists($TemporaryPath)) {
            [IO.File]::Delete($TemporaryPath)
        }
        if ([IO.File]::Exists($BackupPath)) {
            try {
                [IO.File]::Delete($BackupPath)
            } catch {
                Write-Warning "An atomic-write backup could not be removed: $BackupPath"
            }
        }
    }
}

function Enter-XvenvFileLock {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$TimeoutSeconds = 600
    )

    $FullPath = Get-XvenvFullPath $Path
    [void][IO.Directory]::CreateDirectory((Split-Path $FullPath -Parent))
    $Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    # The persistent zero-byte file is only a name. FileShare.None on the
    # live handle is the lock, so a crashed process cannot leave a stale lock.
    while ([DateTime]::UtcNow -lt $Deadline) {
        try {
            return [IO.File]::Open(
                $FullPath,
                [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None
            )
        } catch [IO.IOException] {
            Start-Sleep -Milliseconds 200
        }
    }
    throw "Timed out waiting for xvenv lock: $FullPath"
}

function Assert-XvenvPathInsideRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $FullPath = Get-XvenvFullPath $Path
    $FullRoot = Get-XvenvFullPath $Root
    $RootPrefix = $FullRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ($FullPath.Equals($FullRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not $FullPath.StartsWith($RootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing $Context outside the controlled data root: $FullPath"
    }
    return $FullPath
}

function Remove-XvenvControlledPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $FullPath = Assert-XvenvPathInsideRoot -Path $Path -Root $Root -Context $Context
    if ([IO.Directory]::Exists($FullPath)) {
        Remove-Item -LiteralPath $FullPath -Recurse -Force
    } elseif ([IO.File]::Exists($FullPath)) {
        [IO.File]::Delete($FullPath)
    }
}
