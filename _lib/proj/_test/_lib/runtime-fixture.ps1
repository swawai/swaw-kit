Set-StrictMode -Version 2.0

$script:ProjRuntimeFixtureRepoRoot = [IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\..\..\..')
)
. (Join-Path $script:ProjRuntimeFixtureRepoRoot (
    '_lib\proj\_bootstrap\layout.ps1'
))
. (Join-Path $script:ProjRuntimeFixtureRepoRoot (
    '_lib\proj\_toolchain\_lib\runtime.ps1'
))
. (Join-Path $script:ProjRuntimeFixtureRepoRoot (
    '_lib\proj\_runtime\release.ps1'
))

function Assert-ProjCandidateRuntimeFixtureRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $Path = [IO.Path]::GetFullPath($Path)
    $TestRoot = [IO.Path]::GetFullPath((Join-Path (
        $script:ProjRuntimeFixtureRepoRoot
    ) 'data\_test')).TrimEnd('\') + '\'
    if (-not $Path.StartsWith(
        $TestRoot,
        [StringComparison]::OrdinalIgnoreCase
    ) -or
        -not [IO.Path]::GetFileName($Path).StartsWith(
            'swawkit-proj-',
            [StringComparison]::Ordinal
        )) {
        throw "Unsafe candidate runtime fixture root: $Path"
    }
    return $Path
}

function Copy-ProjFixtureHardLinkTree {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    [void][IO.Directory]::CreateDirectory($Destination)
    foreach ($Item in Get-ChildItem -LiteralPath $Source -Recurse -Force) {
        $Relative = $Item.FullName.Substring($Source.TrimEnd('\').Length + 1)
        $Target = Join-Path $Destination $Relative
        if ($Item.PSIsContainer) {
            [void][IO.Directory]::CreateDirectory($Target)
        } else {
            [void][IO.Directory]::CreateDirectory((Split-Path $Target -Parent))
            [void](New-Item -ItemType HardLink -Path $Target -Value $Item.FullName)
        }
    }
}

function Copy-ProjFixtureCommandRuntime {
    param([Parameter(Mandatory = $true)][string]$RuntimeHome)

    $SourceBootstrap = Join-Path `
        $script:ProjRuntimeFixtureRepoRoot `
        'data\proj_cache\bootstrap'
    $Selector = Join-Path $SourceBootstrap 'command-runtimes\current'
    $RuntimeId = [IO.File]::ReadAllText(
        $Selector,
        [Text.Encoding]::UTF8
    ).Trim()
    $Runtime = Read-ProjCommandRuntime `
        -BootstrapDataRoot $SourceBootstrap `
        -RuntimeId $RuntimeId
    $TargetBootstrap = Join-Path $RuntimeHome 'data\proj_cache\bootstrap'
    foreach ($Tool in @($Runtime.Tools)) {
        $RelativePath = ([string]$Tool.path).Replace('/', '\')
        $SourceTool = Join-Path $SourceBootstrap $RelativePath
        $RelativeRoot = Split-Path $RelativePath -Parent
        $SourceRoot = Split-Path $SourceTool -Parent
        $TargetRoot = Join-Path $TargetBootstrap $RelativeRoot
        if (-not [IO.Directory]::Exists($TargetRoot)) {
            Copy-ProjFixtureHardLinkTree `
                -Source $SourceRoot `
                -Destination $TargetRoot
        }
    }
    $TargetRelease = Join-Path `
        $TargetBootstrap `
        "command-runtimes\releases\$RuntimeId"
    [void][IO.Directory]::CreateDirectory($TargetRelease)
    [IO.File]::Copy(
        (Join-Path $Runtime.Root 'manifest.json'),
        (Join-Path $TargetRelease 'manifest.json'),
        $false
    )
    return $RuntimeId
}

function Add-ProjFixtureCommandManifest {
    param([Parameter(Mandatory = $true)][string]$CommandRoot)

    [void][IO.Directory]::CreateDirectory($CommandRoot)
    $Manifest = [ordered]@{
        schema = 'swawkit.command-module/v11'
        requires = @()
        provides = @()
    }
    [IO.File]::WriteAllText(
        (Join-Path $CommandRoot 'swawkit.module.json'),
        (($Manifest | ConvertTo-Json -Depth 4) + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
}

function Resolve-ProjCandidateRuntimeArtifacts {
    param(
        [string]$LauncherPath = '',
        [string]$CorePath = '',
        [string]$HostPath = '',
        [string]$ModulePath = '',
        [string]$DevPath = ''
    )

    $BuildDefaults = [string]::IsNullOrWhiteSpace($LauncherPath) -or
        [string]::IsNullOrWhiteSpace($CorePath) -or
        [string]::IsNullOrWhiteSpace($HostPath) -or
        [string]::IsNullOrWhiteSpace($ModulePath) -or
        [string]::IsNullOrWhiteSpace($DevPath)
    $Layout = Get-ProjBootstrapLayout
    if ([string]::IsNullOrWhiteSpace($LauncherPath)) {
        $LauncherPath = $Layout.LauncherCandidatePath
    }
    if ([string]::IsNullOrWhiteSpace($CorePath)) {
        $CorePath = Join-Path $Layout.BuildRoot 'release\swawkit-proj.exe'
    }
    if ([string]::IsNullOrWhiteSpace($HostPath)) {
        $HostPath = Join-Path $Layout.BuildRoot 'release\swawkit-proj-host.exe'
    }
    if ([string]::IsNullOrWhiteSpace($DevPath)) {
        $DevPath = $Layout.DevCandidatePath
    }
    if ([string]::IsNullOrWhiteSpace($ModulePath)) {
        $ModulePath = $Layout.ModuleCandidatePath
    }
    if ($BuildDefaults) {
        & (Join-Path $script:ProjRuntimeFixtureRepoRoot (
            '_lib\proj\build.ps1'
        )) | Out-Host
    }

    $LauncherPath = [IO.Path]::GetFullPath($LauncherPath)
    $CorePath = [IO.Path]::GetFullPath($CorePath)
    $HostPath = [IO.Path]::GetFullPath($HostPath)
    $ModulePath = [IO.Path]::GetFullPath($ModulePath)
    $DevPath = [IO.Path]::GetFullPath($DevPath)
    foreach ($RequiredFile in @(
        $LauncherPath,
        $CorePath,
        $HostPath,
        $ModulePath,
        $DevPath
    )) {
        if (-not [IO.File]::Exists($RequiredFile)) {
            throw "Required built executable does not exist: $RequiredFile"
        }
    }

    return [pscustomobject][ordered]@{
        LauncherPath = $LauncherPath
        CorePath = $CorePath
        HostPath = $HostPath
        ModulePath = $ModulePath
        DevPath = $DevPath
    }
}

function New-ProjCandidateRuntimeFixture {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeHome,
        [Parameter(Mandatory = $true)][string]$LauncherPath,
        [Parameter(Mandatory = $true)][string]$CorePath,
        [Parameter(Mandatory = $true)][string]$HostPath,
        [Parameter(Mandatory = $true)][string]$ModulePath,
        [Parameter(Mandatory = $true)][string]$DevPath
    )

    $RuntimeHome = [IO.Path]::GetFullPath($RuntimeHome)
    if ([IO.Path]::GetFileName($RuntimeHome) -cne 'runtime-home') {
        throw "Candidate RuntimeHome must end in 'runtime-home': $RuntimeHome"
    }
    [void](Assert-ProjCandidateRuntimeFixtureRoot `
        -Path (Split-Path -Path $RuntimeHome -Parent))
    $KernelRoot = Join-Path $RuntimeHome '_lib\proj'
    [void][IO.Directory]::CreateDirectory($KernelRoot)
    $CommandRuntimeId = Copy-ProjFixtureCommandRuntime -RuntimeHome $RuntimeHome
    $ReleaseSet = New-ProjRuntimeReleaseSetFromFiles `
        -Artifacts ([ordered]@{
            'swawkit-proj.exe' = $CorePath
            'swawkit-proj-host.exe' = $HostPath
            'swawkit-proj-module.exe' = $ModulePath
            'swawkit-proj-dev.exe' = $DevPath
        }) `
        -CommandRuntimeId $CommandRuntimeId

    foreach ($RelativeDirectory in @(
        'system',
        '_toolchain'
    )) {
        Copy-Item `
            -LiteralPath (Join-Path (
                $script:ProjRuntimeFixtureRepoRoot
            ) "_lib\proj\$RelativeDirectory") `
            -Destination $KernelRoot `
            -Recurse `
            -Force
    }
    [void][IO.Directory]::CreateDirectory((Join-Path $RuntimeHome '.swaw'))

    return [pscustomobject][ordered]@{
        Home = $RuntimeHome
        KernelRoot = $KernelRoot
        DataRoot = ''
        RuntimeRoot = ''
        RuntimeRelease = ''
        ReleaseId = ''
        EntryId = ''
        EntryPath = ''
        CommandRuntimeId = $CommandRuntimeId
        ReleaseSet = $ReleaseSet
        LauncherPath = [IO.Path]::GetFullPath($LauncherPath)
    }
}

function Add-ProjCandidateRuntimeEntry {
    param(
        [Parameter(Mandatory = $true)][object]$Runtime,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $EntryPath = [IO.Path]::GetFullPath((Join-Path $Runtime.Home $RelativePath))
    $RuntimePrefix = $Runtime.Home.TrimEnd('\') + '\'
    if (-not $EntryPath.StartsWith(
        $RuntimePrefix,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Entry path escaped the candidate runtime: $EntryPath"
    }
    if (-not [string]::IsNullOrEmpty([string]$Runtime.EntryPath)) {
        throw "Candidate runtime already belongs to an Entry: $($Runtime.EntryPath)"
    }
    if (-not [IO.Path]::GetExtension($EntryPath).Equals(
        '.exe',
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Candidate runtime Entry must have an .exe suffix: $EntryPath"
    }
    $EntryName = [IO.Path]::GetFileNameWithoutExtension($EntryPath)
    if ([string]::IsNullOrWhiteSpace($EntryName)) {
        throw "Candidate runtime Entry has no usable file name: $EntryPath"
    }
    $DataRootName = if ($EntryName.Equals(
        'swawkit',
        [StringComparison]::OrdinalIgnoreCase
    )) {
        'swawkit'
    } else {
        $EntryName
    }
    $DataRoot = Join-Path $Runtime.Home "data\proj.$DataRootName"
    if ([IO.Directory]::Exists($DataRoot) -or [IO.File]::Exists($DataRoot)) {
        throw "Candidate Runtime DataRoot already exists: $DataRoot"
    }
    [void][IO.Directory]::CreateDirectory($DataRoot)
    $EntryId = (
        [Guid]::NewGuid().ToString('N') +
        [Guid]::NewGuid().ToString('N')
    ).ToLowerInvariant()
    [IO.File]::WriteAllText(
        (Join-Path $DataRoot 'entry.id'),
        ($EntryId + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
    $RuntimeRoot = Join-Path $DataRoot 'runtime'
    $Published = Publish-ProjRuntimeReleaseSet `
        -ReleaseSet $Runtime.ReleaseSet `
        -RuntimeRoot $RuntimeRoot `
        -ProjHome $Runtime.Home `
        -CacheDataRoot (Join-Path $Runtime.Home 'data\proj_cache')

    [void][IO.Directory]::CreateDirectory((Split-Path -Path $EntryPath -Parent))
    [IO.File]::Copy($Runtime.LauncherPath, $EntryPath, $false)
    $Runtime.DataRoot = $DataRoot
    $Runtime.RuntimeRoot = $RuntimeRoot
    $Runtime.RuntimeRelease = [string]$Published.Root
    $Runtime.ReleaseId = [string]$Published.ReleaseId
    $Runtime.EntryId = $EntryId
    $Runtime.EntryPath = $EntryPath
    return $EntryPath
}

function Remove-ProjCandidateRuntimeFixture {
    param([Parameter(Mandatory = $true)][string]$Path)

    $Path = Assert-ProjCandidateRuntimeFixtureRoot -Path $Path

    $Deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ([IO.Directory]::Exists($Path)) {
        try {
            [IO.Directory]::Delete($Path, $true)
            return
        } catch {
            if ([DateTime]::UtcNow -ge $Deadline) {
                throw
            }
            Start-Sleep -Milliseconds 50
        }
    }
}
