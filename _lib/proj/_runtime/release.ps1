Set-StrictMode -Version 2.0

$SharedToolchainLibrary = [IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\_toolchain\_lib')
)
. (Join-Path $SharedToolchainLibrary 'foundation.ps1')
. (Join-Path $SharedToolchainLibrary 'controlled-path.ps1')
. (Join-Path $PSScriptRoot 'command-runtime.ps1')

$script:ProjRuntimeReleaseManifestSchema = 'swawkit.proj-release-set/v4'
$script:ProjRuntimeReleaseMaxManifestBytes = 1MB
$script:ProjRuntimeReleaseMaxArtifactBytes = 512MB

function Get-ProjRuntimeOrdinalNames {
    param([Parameter(Mandatory = $true)][string[]]$Names)

    [string[]]$Sorted = @($Names)
    [Array]::Sort($Sorted, [StringComparer]::Ordinal)
    return $Sorted
}

function New-ProjRuntimeReleaseSetFromFiles {
    param(
        [Parameter(Mandatory = $true)]
        [Collections.IDictionary]$Artifacts,
        [Parameter(Mandatory = $true)][string]$CommandRuntimeId
    )

    if ($CommandRuntimeId -cnotmatch '^[a-f0-9]{64}$') {
        throw 'The application Command Runtime ID is invalid.'
    }

    $Records = [Collections.Generic.List[object]]::new()
    $Identity = [Collections.Generic.List[string]]::new()
    $Identity.Add($script:ProjRuntimeReleaseManifestSchema)
    $Identity.Add($CommandRuntimeId)
    [string[]]$ArtifactNames = Get-ProjRuntimeOrdinalNames `
        -Names ([string[]]@($Artifacts.Keys))
    foreach ($Name in $ArtifactNames) {
        if ($Name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') {
            throw "Invalid runtime Release Set artifact name: '$Name'"
        }
        $Path = [IO.Path]::GetFullPath([string]$Artifacts[$Name])
        if (-not [IO.File]::Exists($Path)) {
            throw "The runtime Release Set artifact is missing: $Path"
        }
        $Item = Get-Item -LiteralPath $Path
        if ($Item.Length -le 0 -or
            $Item.Length -gt $script:ProjRuntimeReleaseMaxArtifactBytes -or
            ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "The runtime Release Set artifact is invalid: $Path"
        }
        $Hash = Get-ProjDevFileSha256 -Path $Path
        $Records.Add([pscustomobject][ordered]@{
            Name = $Name
            Path = $Path
            Length = [long]$Item.Length
            Sha256 = $Hash
        })
        $Identity.Add($Name)
        $Identity.Add(([long]$Item.Length).ToString(
            [Globalization.CultureInfo]::InvariantCulture
        ))
        $Identity.Add($Hash)
    }
    $Names = [string[]]@($Records | ForEach-Object Name | Sort-Object)
    if ($Names.Count -ne 4 -or
        $Names -cnotcontains 'swawkit-proj.exe' -or
        $Names -cnotcontains 'swawkit-proj-host.exe' -or
        $Names -cnotcontains 'swawkit-proj-module.exe' -or
        $Names -cnotcontains 'swawkit-proj-dev.exe') {
        throw (
            'The application Release Set must contain exactly Core, Host, ' +
            'Module, and Dev.'
        )
    }
    return [pscustomobject][ordered]@{
        ReleaseId = Get-ProjDevSha256Text `
            -Value ([string]::Join("`n", $Identity))
        CommandRuntimeId = $CommandRuntimeId
        Artifacts = [object[]]$Records
    }
}

function Publish-ProjRuntimeReleaseSet {
    param(
        [Parameter(Mandatory = $true)][object]$ReleaseSet,
        [Parameter(Mandatory = $true)][string]$ProjHome,
        [Parameter(Mandatory = $true)][string]$CacheDataRoot
    )

    $ArtifactPaths = [ordered]@{}
    foreach ($Artifact in @($ReleaseSet.Artifacts)) {
        $Name = [string]$Artifact.Name
        if ($ArtifactPaths.Contains($Name)) {
            throw "The application Release Set repeats '$Name'."
        }
        $ArtifactPaths[$Name] = [string]$Artifact.Path
    }
    $VerifiedReleaseSet = New-ProjRuntimeReleaseSetFromFiles `
        -Artifacts $ArtifactPaths `
        -CommandRuntimeId ([string]$ReleaseSet.CommandRuntimeId)
    $ReleaseId = [string]$ReleaseSet.ReleaseId
    if ($ReleaseId -cnotmatch '^[a-f0-9]{64}$') {
        throw 'The application Release Set ID is invalid.'
    }
    if ($ReleaseId -cne [string]$VerifiedReleaseSet.ReleaseId) {
        throw 'The application Release Set ID does not match its artifacts.'
    }
    $ReleaseSet = $VerifiedReleaseSet
    $ProjHome = Get-ProjDevFullPath -Path $ProjHome
    [void](Read-ProjCommandRuntime `
        -BootstrapDataRoot (Join-Path $ProjHome 'data\proj_cache\bootstrap') `
        -RuntimeId ([string]$VerifiedReleaseSet.CommandRuntimeId))
    $CacheDataRoot = Assert-ProjDevControlledRoot `
        -Root $CacheDataRoot `
        -Description 'shared project cache data root'
    $RuntimeRoot = Join-Path $ProjHome '_lib\proj\_bin'
    Assert-ProjRuntimeDirectory -Path $RuntimeRoot -Create
    $PublishLock = Enter-ProjDevFileLock `
        -Path (Join-Path $CacheDataRoot 'locks\release-publish.lock') `
        -ControlledRoot $CacheDataRoot `
        -TimeoutSeconds 120
    try {
        $ReleasesRoot = Join-Path $RuntimeRoot 'releases'
        Assert-ProjRuntimeDirectory -Path $ReleasesRoot -Create
        $ReleaseRoot = Join-Path $ReleasesRoot $ReleaseId
        if (-not [IO.Directory]::Exists($ReleaseRoot)) {
            Publish-ProjRuntimeReleaseDirectory `
                -ReleaseSet $ReleaseSet `
                -ReleasesRoot $ReleasesRoot `
                -ReleaseRoot $ReleaseRoot
        }
        $RuntimeRelease = Read-ProjRuntimeReleaseSet `
            -ReleaseRoot $ReleaseRoot `
            -ReleaseId $ReleaseId

        Publish-ProjRuntimeSelector `
            -RuntimeRoot $RuntimeRoot `
            -ReleaseId $ReleaseId
        Write-Host "[PUBLISHED] Release Set $ReleaseId" -ForegroundColor Green
        return $RuntimeRelease
    } finally {
        $PublishLock.Dispose()
    }
}

function Publish-ProjRuntimeReleaseDirectory {
    param(
        [Parameter(Mandatory = $true)][object]$ReleaseSet,
        [Parameter(Mandatory = $true)][string]$ReleasesRoot,
        [Parameter(Mandatory = $true)][string]$ReleaseRoot
    )

    $StageRoot = Join-Path $ReleasesRoot (
        ".$($ReleaseSet.ReleaseId).$([Guid]::NewGuid().ToString('N')).tmp"
    )
    [void][IO.Directory]::CreateDirectory($StageRoot)
    $Committed = $false
    try {
        $ManifestArtifacts = [Collections.Generic.List[object]]::new()
        foreach ($Artifact in @($ReleaseSet.Artifacts | Sort-Object Name)) {
            $Destination = Join-Path $StageRoot ([string]$Artifact.Name)
            [IO.File]::Copy([string]$Artifact.Path, $Destination, $false)
            $Item = Get-Item -LiteralPath $Destination
            $Hash = Get-ProjDevFileSha256 -Path $Destination
            if ([long]$Item.Length -ne [long]$Artifact.Length -or
                $Hash -cne [string]$Artifact.Sha256) {
                throw "The staged runtime Release Set artifact is corrupt: $Destination"
            }
            $ManifestArtifacts.Add([ordered]@{
                name = [string]$Artifact.Name
                length = [long]$Item.Length
                sha256 = $Hash
            })
        }
        $Manifest = [ordered]@{
            schema = $script:ProjRuntimeReleaseManifestSchema
            releaseId = [string]$ReleaseSet.ReleaseId
            commandRuntimeId = [string]$ReleaseSet.CommandRuntimeId
            artifacts = [object[]]$ManifestArtifacts
        }
        [IO.File]::WriteAllText(
            (Join-Path $StageRoot 'manifest.json'),
            (ConvertTo-ProjDevJsonText -Value $Manifest),
            [Text.UTF8Encoding]::new($false)
        )
        [IO.Directory]::Move($StageRoot, $ReleaseRoot)
        $Committed = $true
    } finally {
        if (-not $Committed -and [IO.Directory]::Exists($StageRoot)) {
            [IO.Directory]::Delete($StageRoot, $true)
        }
    }
}

function Read-ProjRuntimeReleaseSet {
    param(
        [Parameter(Mandatory = $true)][string]$ReleaseRoot,
        [Parameter(Mandatory = $true)][string]$ReleaseId
    )

    $ReleaseRoot = [IO.Path]::GetFullPath($ReleaseRoot)
    $ReleasesRoot = Split-Path $ReleaseRoot -Parent
    $RuntimeRoot = Split-Path $ReleasesRoot -Parent
    if ((Split-Path $ReleaseRoot -Leaf) -cne $ReleaseId -or
        (Split-Path $ReleasesRoot -Leaf) -cne 'releases') {
        throw "The runtime Release Set path is invalid: $ReleaseRoot"
    }
    Assert-ProjRuntimeDirectory -Path $RuntimeRoot
    Assert-ProjRuntimeDirectory -Path $ReleasesRoot
    Assert-ProjRuntimeDirectory -Path $ReleaseRoot
    $ExpectedMembers = [string[]]@(
        'manifest.json',
        'swawkit-proj.exe',
        'swawkit-proj-host.exe',
        'swawkit-proj-module.exe',
        'swawkit-proj-dev.exe'
    )
    try {
        $ActualMembers = [string[]]@(
            Get-ChildItem -LiteralPath $ReleaseRoot -Force |
                ForEach-Object Name
        )
    } catch {
        throw "The runtime Release Set membership is unreadable: $ReleaseRoot"
    }
    $ValidMembership = $ActualMembers.Count -eq $ExpectedMembers.Count
    if ($ValidMembership) {
        foreach ($ExpectedMember in $ExpectedMembers) {
            if ($ActualMembers -cnotcontains $ExpectedMember) {
                $ValidMembership = $false
                break
            }
        }
    }
    if (-not $ValidMembership) {
        throw "The runtime Release Set directory membership is invalid: $ReleaseRoot"
    }
    $ManifestPath = Join-Path $ReleaseRoot 'manifest.json'
    $ManifestItem = Get-Item `
        -LiteralPath $ManifestPath `
        -Force `
        -ErrorAction SilentlyContinue
    if ($null -eq $ManifestItem -or $ManifestItem.PSIsContainer -or
        ($ManifestItem.Attributes -band
            [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $ManifestItem.Length -le 0 -or
        $ManifestItem.Length -gt $script:ProjRuntimeReleaseMaxManifestBytes) {
        throw "The runtime Release Set manifest is invalid: $ManifestPath"
    }
    try {
        $Manifest = [IO.File]::ReadAllText(
            $ManifestPath,
            [Text.Encoding]::UTF8
        ) | ConvertFrom-Json
    } catch {
        throw "The runtime Release Set manifest is invalid: $ManifestPath"
    }
    $Fields = [string[]]@($Manifest.PSObject.Properties.Name)
    if ($Fields.Count -ne 4 -or
        $Fields -cnotcontains 'schema' -or
        $Fields -cnotcontains 'releaseId' -or
        $Fields -cnotcontains 'commandRuntimeId' -or
        $Fields -cnotcontains 'artifacts' -or
        [string]$Manifest.schema -cne $script:ProjRuntimeReleaseManifestSchema -or
        [string]$Manifest.releaseId -cne $ReleaseId -or
        [string]$Manifest.commandRuntimeId -cnotmatch '^[a-f0-9]{64}$') {
        throw "The runtime Release Set manifest is invalid: $ManifestPath"
    }
    $Artifacts = [Collections.Generic.List[object]]::new()
    foreach ($Record in @($Manifest.artifacts)) {
        $RecordFields = [string[]]@($Record.PSObject.Properties.Name)
        if ($RecordFields.Count -ne 3 -or
            $RecordFields -cnotcontains 'name' -or
            $RecordFields -cnotcontains 'length' -or
            $RecordFields -cnotcontains 'sha256') {
            throw "The runtime Release Set manifest is invalid: $ManifestPath"
        }
        $Name = [string]$Record.name
        $Path = Join-Path $ReleaseRoot $Name
        if ($Name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$' -or
            -not [IO.File]::Exists($Path)) {
            throw "The runtime Release Set artifact is missing: $Path"
        }
        $Item = Get-Item -LiteralPath $Path
        if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            [long]$Record.length -le 0 -or
            [long]$Record.length -gt $script:ProjRuntimeReleaseMaxArtifactBytes -or
            [long]$Item.Length -gt $script:ProjRuntimeReleaseMaxArtifactBytes -or
            [long]$Record.length -ne [long]$Item.Length -or
            [string]$Record.sha256 -cnotmatch '^[a-f0-9]{64}$') {
            throw "The runtime Release Set artifact is corrupt: $Path"
        }
        $Hash = Get-ProjDevFileSha256 -Path $Path
        if ([string]$Record.sha256 -cne $Hash) {
            throw "The runtime Release Set artifact is corrupt: $Path"
        }
        $Artifacts.Add([pscustomobject][ordered]@{
            Name = $Name
            Path = $Path
            Length = [long]$Item.Length
            Sha256 = $Hash
        })
    }
    $Names = [string[]]@($Artifacts | ForEach-Object Name | Sort-Object)
    if ($Names.Count -ne 4 -or
        $Names -cnotcontains 'swawkit-proj.exe' -or
        $Names -cnotcontains 'swawkit-proj-host.exe' -or
        $Names -cnotcontains 'swawkit-proj-module.exe' -or
        $Names -cnotcontains 'swawkit-proj-dev.exe') {
        throw "The runtime Release Set has invalid membership: $ManifestPath"
    }
    $Identity = [Collections.Generic.List[string]]::new()
    $Identity.Add($script:ProjRuntimeReleaseManifestSchema)
    $Identity.Add([string]$Manifest.commandRuntimeId)
    [string[]]$IdentityNames = Get-ProjRuntimeOrdinalNames -Names $Names
    foreach ($Name in $IdentityNames) {
        $Artifact = @($Artifacts | Where-Object {
            [string]$_.Name -ceq $Name
        })[0]
        $Identity.Add([string]$Artifact.Name)
        $Identity.Add(([long]$Artifact.Length).ToString(
            [Globalization.CultureInfo]::InvariantCulture
        ))
        $Identity.Add([string]$Artifact.Sha256)
    }
    $ComputedId = Get-ProjDevSha256Text `
        -Value ([string]::Join("`n", $Identity))
    if ($ComputedId -cne $ReleaseId) {
        throw "The runtime Release Set ID does not match its artifacts: $ManifestPath"
    }
    $ProjRoot = Split-Path $RuntimeRoot -Parent
    $LibraryRoot = Split-Path $ProjRoot -Parent
    $ProjHome = Split-Path $LibraryRoot -Parent
    [void](Read-ProjCommandRuntime `
        -BootstrapDataRoot (Join-Path $ProjHome 'data\proj_cache\bootstrap') `
        -RuntimeId ([string]$Manifest.commandRuntimeId))
    return [pscustomobject][ordered]@{
        ReleaseId = $ReleaseId
        CommandRuntimeId = [string]$Manifest.commandRuntimeId
        Root = $ReleaseRoot
        ManifestPath = $ManifestPath
        Artifacts = [object[]]$Artifacts
    }
}

function Read-ProjSelectedRuntimeReleaseSet {
    param([Parameter(Mandatory = $true)][string]$RuntimeRoot)

    $RuntimeRoot = [IO.Path]::GetFullPath($RuntimeRoot)
    Assert-ProjRuntimeDirectory -Path $RuntimeRoot
    $Current = Join-Path $RuntimeRoot 'current'
    $CurrentItem = Get-Item `
        -LiteralPath $Current `
        -Force `
        -ErrorAction SilentlyContinue
    if ($null -eq $CurrentItem -or $CurrentItem.PSIsContainer -or
        ($CurrentItem.Attributes -band
            [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The runtime Release Set selector is unsafe or missing: $Current"
    }
    try {
        [byte[]]$Selector = [IO.File]::ReadAllBytes($Current)
    } catch {
        throw "The runtime Release Set selector is unreadable: $Current"
    }
    if ($Selector.Count -ne 65 -or $Selector[64] -ne 10) {
        throw "The runtime Release Set selector is invalid: $Current"
    }
    $ReleaseId = [Text.Encoding]::ASCII.GetString($Selector, 0, 64)
    if ($ReleaseId -cnotmatch '^[a-f0-9]{64}$') {
        throw "The runtime Release Set selector is invalid: $Current"
    }
    return Read-ProjRuntimeReleaseSet `
        -ReleaseRoot (Join-Path (Join-Path $RuntimeRoot 'releases') $ReleaseId) `
        -ReleaseId $ReleaseId
}

function Publish-ProjRuntimeSelector {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$ReleaseId
    )

    $Current = Join-Path $RuntimeRoot 'current'
    $CurrentItem = Get-Item -LiteralPath $Current -Force -ErrorAction SilentlyContinue
    if ($null -ne $CurrentItem -and
        ($CurrentItem.PSIsContainer -or
            ($CurrentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "The runtime Release Set selector is unsafe: $Current"
    }
    if ([IO.File]::Exists($Current) -and
        [IO.File]::ReadAllText($Current, [Text.Encoding]::UTF8) -ceq
            ($ReleaseId + "`n")) {
        return
    }
    $Token = [Guid]::NewGuid().ToString('N')
    $Stage = Join-Path $RuntimeRoot ".current.$Token.tmp"
    $Backup = Join-Path $RuntimeRoot ".current.$Token.backup"
    try {
        [IO.File]::WriteAllText(
            $Stage,
            ($ReleaseId + "`n"),
            [Text.UTF8Encoding]::new($false)
        )
        if ([IO.File]::Exists($Current)) {
            [IO.File]::Replace($Stage, $Current, $Backup, $true)
        } else {
            [IO.File]::Move($Stage, $Current)
        }
    } finally {
        foreach ($Path in @($Stage, $Backup)) {
            if ([IO.File]::Exists($Path)) {
                [IO.File]::Delete($Path)
            }
        }
    }
}

function Assert-ProjRuntimeDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Create
    )

    if ($Create -and -not [IO.Directory]::Exists($Path)) {
        [void][IO.Directory]::CreateDirectory($Path)
    }
    $Item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $Item -or -not $Item.PSIsContainer -or
        ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The runtime Release Set directory is unsafe: $Path"
    }
}
