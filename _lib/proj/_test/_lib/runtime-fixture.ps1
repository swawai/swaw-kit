Set-StrictMode -Version 2.0

$script:ProjRuntimeFixtureRepoRoot = [IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\..\..\..')
)
. (Join-Path $script:ProjRuntimeFixtureRepoRoot (
    '_lib\proj\_toolchain\bootstrap-layout.ps1'
))
. (Join-Path $script:ProjRuntimeFixtureRepoRoot (
    '_lib\proj\_toolchain\runtime.ps1'
))
. (Join-Path $script:ProjRuntimeFixtureRepoRoot (
    '_lib\proj\_toolchain\_lib\runtime-release.ps1'
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

function Add-ProjFixtureCommandManifest {
    param([Parameter(Mandatory = $true)][string]$CommandRoot)

    [void][IO.Directory]::CreateDirectory($CommandRoot)
    $Manifest = [ordered]@{
        schema = 'swawkit.command-module/v10'
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
        [string]$ToolchainPath = ''
    )

    $BuildDefaults = [string]::IsNullOrWhiteSpace($LauncherPath) -or
        [string]::IsNullOrWhiteSpace($CorePath) -or
        [string]::IsNullOrWhiteSpace($HostPath) -or
        [string]::IsNullOrWhiteSpace($ModulePath) -or
        [string]::IsNullOrWhiteSpace($ToolchainPath)
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
    if ([string]::IsNullOrWhiteSpace($ToolchainPath)) {
        $ToolchainPath = Join-Path $Layout.BuildRoot (
            'release\swawkit-proj-toolchain.exe'
        )
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
    $ToolchainPath = [IO.Path]::GetFullPath($ToolchainPath)
    foreach ($RequiredFile in @(
        $LauncherPath,
        $CorePath,
        $HostPath,
        $ModulePath,
        $ToolchainPath
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
        ToolchainPath = $ToolchainPath
    }
}

function New-ProjCandidateRuntimeFixture {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeHome,
        [Parameter(Mandatory = $true)][string]$LauncherPath,
        [Parameter(Mandatory = $true)][string]$CorePath,
        [Parameter(Mandatory = $true)][string]$HostPath,
        [Parameter(Mandatory = $true)][string]$ModulePath,
        [Parameter(Mandatory = $true)][string]$ToolchainPath
    )

    $RuntimeHome = [IO.Path]::GetFullPath($RuntimeHome)
    if ([IO.Path]::GetFileName($RuntimeHome) -cne 'runtime-home') {
        throw "Candidate RuntimeHome must end in 'runtime-home': $RuntimeHome"
    }
    [void](Assert-ProjCandidateRuntimeFixtureRoot `
        -Path (Split-Path -Path $RuntimeHome -Parent))
    $KernelRoot = Join-Path $RuntimeHome '_lib\proj'
    $RuntimeBin = Join-Path $KernelRoot '_bin'
    [void][IO.Directory]::CreateDirectory($KernelRoot)
    $ReleaseSet = New-ProjRuntimeReleaseSetFromFiles -Artifacts ([ordered]@{
        'swawkit-proj.exe' = $CorePath
        'swawkit-proj-host.exe' = $HostPath
        'swawkit-proj-module.exe' = $ModulePath
        'swawkit-proj-toolchain.exe' = $ToolchainPath
    })
    $Published = Publish-ProjRuntimeReleaseSet `
        -ReleaseSet $ReleaseSet `
        -ProjHome $RuntimeHome `
        -CacheDataRoot (Join-Path $RuntimeHome 'data\proj_cache')
    $RuntimeRelease = [string]$Published.Root

    foreach ($RelativeDirectory in @(
        'system',
        '_shell',
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
    [void][IO.Directory]::CreateDirectory((Join-Path $KernelRoot 'modules'))
    [void][IO.Directory]::CreateDirectory((Join-Path $RuntimeHome '.swaw'))

    return [pscustomobject][ordered]@{
        Home = $RuntimeHome
        KernelRoot = $KernelRoot
        RuntimeBin = $RuntimeBin
        RuntimeRelease = $RuntimeRelease
        ReleaseId = [string]$Published.ReleaseId
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
    [void][IO.Directory]::CreateDirectory((Split-Path -Path $EntryPath -Parent))
    [IO.File]::Copy($Runtime.LauncherPath, $EntryPath, $false)
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
