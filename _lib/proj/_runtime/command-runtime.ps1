Set-StrictMode -Version 2.0

$SharedToolchainLibrary = [IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\_toolchain\_lib')
)
. (Join-Path $SharedToolchainLibrary 'foundation.ps1')
. (Join-Path $SharedToolchainLibrary 'controlled-path.ps1')

$script:ProjCommandRuntimeSchema = 'swawkit.proj-command-runtime/v1'
$script:ProjCommandRuntimeMaxManifestBytes = 64KB
$script:ProjCommandRuntimeMaxToolBytes = 512MB

function New-ProjBootstrapCommandRuntimeDefinitions {
    param([Parameter(Mandatory = $true)][object]$Contract)

    $Values = [ordered]@{
        SWAWKIT_PROJ_BUN_MODE = 'managed'
        SWAWKIT_PROJ_BUN_VERSION = [string]$Contract.BunVersion
        SWAWKIT_PROJ_BUN_SHA256 = [string]$Contract.BunSha256
        SWAWKIT_PROJ_PWSH_MODE = 'managed'
        SWAWKIT_PROJ_PWSH_VERSION = [string]$Contract.PwshVersion
        SWAWKIT_PROJ_PWSH_SHA256 = [string]$Contract.PwshSha256
    }
    $Saved = [ordered]@{}
    foreach ($Name in $Values.Keys) {
        $Saved[$Name] = [Environment]::GetEnvironmentVariable($Name, 'Process')
        [Environment]::SetEnvironmentVariable(
            $Name,
            [string]$Values[$Name],
            'Process'
        )
    }
    try {
        $Bun = Get-ProjDevBunDefinition
        $Pwsh = Get-ProjDevPwshDefinition
        if ($null -eq $Bun -or $null -eq $Pwsh) {
            throw 'The Bootstrap Command Runtime definitions are disabled.'
        }
        # Stage-0 is an exact, offline-capable contract. The project-pinned
        # archive digest is authoritative here; GitHub discovery belongs to
        # the richer, user-facing .dev lifecycle.
        $Bun.ReleaseResolved = $true
        $Pwsh.ReleaseResolved = $true
        return [pscustomobject][ordered]@{
            Bun = $Bun
            Pwsh = $Pwsh
        }
    } finally {
        foreach ($Name in $Saved.Keys) {
            [Environment]::SetEnvironmentVariable(
                $Name,
                $Saved[$Name],
                'Process'
            )
        }
    }
}

function Use-ProjBootstrapCachedCommandRuntimeSource {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Definition
    )

    $NameRoot = Join-Path $Context.CacheRoot ([string]$Definition.Name)
    if (-not [IO.Directory]::Exists($NameRoot)) {
        return
    }
    $ArchiveName = Get-ProjDevSourceFileName -Source ([string]$Definition.Url)
    $Pattern = '{0}-*' -f [string]$Definition.Version
    foreach ($Directory in Get-ChildItem `
        -LiteralPath $NameRoot `
        -Directory `
        -Filter $Pattern `
        -ErrorAction SilentlyContinue) {
        $Candidate = Join-Path $Directory.FullName $ArchiveName
        if ([IO.File]::Exists($Candidate) -and
            (Get-ProjDevFileSha256 -Path $Candidate) -ceq
                [string]$Definition.Sha256) {
            $Definition.Url = $Candidate
            return
        }
    }
}

function New-ProjCommandRuntimeToolRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedName,
        [Parameter(Mandatory = $true)][string]$BootstrapDataRoot
    )

    $BootstrapDataRoot = Assert-ProjDevControlledRoot `
        -Root $BootstrapDataRoot `
        -Description 'Bootstrap data root'
    $Path = Assert-ProjDevPathInsideDataRoot `
        -Path $Path `
        -DataRoot $BootstrapDataRoot `
        -Activity "publishing the $Name Command Runtime"
    $Item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ([IO.Path]::GetFileName($Path) -cne $ExpectedName -or
        -not [IO.File]::Exists($Path) -or
        $Item.Length -le 0 -or
        $Item.Length -gt $script:ProjCommandRuntimeMaxToolBytes -or
        ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The $Name Command Runtime executable is invalid: $Path"
    }
    $Prefix = $BootstrapDataRoot.TrimEnd('\', '/') + '\'
    if (-not $Path.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The $Name Command Runtime escaped the Bootstrap data root."
    }
    $RelativePath = $Path.Substring($Prefix.Length).Replace('\', '/')
    if ($RelativePath -cnotmatch '^[A-Za-z0-9._+-]+(?:/[A-Za-z0-9._+ -]+)*$') {
        throw "The $Name Command Runtime path is not canonical: $RelativePath"
    }
    return [pscustomobject][ordered]@{
        name = $Name
        version = $Version
        path = $RelativePath
        length = [long]$Item.Length
        sha256 = Get-ProjDevFileSha256 -Path $Path
    }
}

function Get-ProjCommandRuntimeId {
    param([Parameter(Mandatory = $true)][object[]]$Tools)

    $Identity = [Collections.Generic.List[string]]::new()
    $Identity.Add($script:ProjCommandRuntimeSchema)
    foreach ($Tool in @($Tools | Sort-Object name)) {
        foreach ($Value in @(
            [string]$Tool.name,
            [string]$Tool.version,
            [string]$Tool.path,
            ([long]$Tool.length).ToString(
                [Globalization.CultureInfo]::InvariantCulture
            ),
            [string]$Tool.sha256
        )) {
            $Identity.Add($Value)
        }
    }
    return Get-ProjDevSha256Text -Value ([string]::Join("`n", $Identity))
}

function Publish-ProjBootstrapCommandRuntime {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Definitions,
        [Parameter(Mandatory = $true)][string]$CommandRuntimeRoot
    )

    $BunRoot = Get-ProjDevInstallRoot `
        -Context $Context `
        -Definition $Definitions.Bun
    $PwshRoot = Get-ProjDevInstallRoot `
        -Context $Context `
        -Definition $Definitions.Pwsh
    $Tools = [object[]]@(
        New-ProjCommandRuntimeToolRecord `
            -Name 'bun' `
            -Version ([string]$Definitions.Bun.Version) `
            -Path (Join-Path $BunRoot ([string]$Definitions.Bun.Executable)) `
            -ExpectedName 'bun.exe' `
            -BootstrapDataRoot $Context.DataRoot
        New-ProjCommandRuntimeToolRecord `
            -Name 'pwsh' `
            -Version ([string]$Definitions.Pwsh.Version) `
            -Path (Join-Path $PwshRoot ([string]$Definitions.Pwsh.Executable)) `
            -ExpectedName 'pwsh.exe' `
            -BootstrapDataRoot $Context.DataRoot
    )
    $RuntimeId = Get-ProjCommandRuntimeId -Tools $Tools
    $CommandRuntimeRoot = Assert-ProjDevPathInsideDataRoot `
        -Path $CommandRuntimeRoot `
        -DataRoot $Context.DataRoot `
        -Activity 'publishing the Bootstrap Command Runtime root'
    $ReleasesRoot = Join-Path $CommandRuntimeRoot 'releases'
    [void][IO.Directory]::CreateDirectory($ReleasesRoot)
    $ReleaseRoot = Join-Path $ReleasesRoot $RuntimeId
    if (-not [IO.Directory]::Exists($ReleaseRoot)) {
        $StageRoot = Join-Path $ReleasesRoot (
            '.staging-{0}-{1}' -f $RuntimeId, [Guid]::NewGuid().ToString('N')
        )
        try {
            [void][IO.Directory]::CreateDirectory($StageRoot)
            $Document = [ordered]@{
                schema = $script:ProjCommandRuntimeSchema
                runtimeId = $RuntimeId
                tools = $Tools
            }
            Write-ProjDevTextAtomic `
                -Path (Join-Path $StageRoot 'manifest.json') `
                -Content (ConvertTo-ProjDevJsonText -Value $Document) `
                -ControlledRoot $Context.DataRoot
            try {
                [IO.Directory]::Move($StageRoot, $ReleaseRoot)
            } catch [IO.IOException] {
                if (-not [IO.Directory]::Exists($ReleaseRoot)) {
                    throw
                }
            }
        } finally {
            if ([IO.Directory]::Exists($StageRoot)) {
                [IO.Directory]::Delete($StageRoot, $true)
            }
        }
    }
    $Runtime = Read-ProjCommandRuntime `
        -BootstrapDataRoot $Context.DataRoot `
        -RuntimeId $RuntimeId
    Write-ProjDevTextAtomic `
        -Path (Join-Path $CommandRuntimeRoot 'current') `
        -Content "$RuntimeId`n" `
        -ControlledRoot $Context.DataRoot
    return $Runtime
}

function Read-ProjCommandRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$BootstrapDataRoot,
        [Parameter(Mandatory = $true)][string]$RuntimeId
    )

    if ($RuntimeId -cnotmatch '^[a-f0-9]{64}$') {
        throw 'The Command Runtime ID is invalid.'
    }
    $BootstrapDataRoot = Assert-ProjDevControlledRoot `
        -Root $BootstrapDataRoot `
        -Description 'Bootstrap data root'
    $Root = Join-Path $BootstrapDataRoot "command-runtimes\releases\$RuntimeId"
    $RootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
    if (-not $RootItem.PSIsContainer -or
        ($RootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The Command Runtime release is unsafe: $Root"
    }
    $Members = @(Get-ChildItem -LiteralPath $Root -Force)
    if ($Members.Count -ne 1 -or $Members[0].Name -cne 'manifest.json') {
        throw "The Command Runtime release membership is invalid: $Root"
    }
    $ManifestPath = Join-Path $Root 'manifest.json'
    $ManifestItem = Get-Item -LiteralPath $ManifestPath -Force
    if ($ManifestItem.PSIsContainer -or
        $ManifestItem.Length -le 0 -or
        $ManifestItem.Length -gt $script:ProjCommandRuntimeMaxManifestBytes -or
        ($ManifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The Command Runtime manifest is invalid: $ManifestPath"
    }
    try {
        $Document = [IO.File]::ReadAllText(
            $ManifestPath,
            [Text.Encoding]::UTF8
        ) | ConvertFrom-Json
    } catch {
        throw "Cannot parse the Command Runtime manifest: $($_.Exception.Message)"
    }
    [string[]]$Properties = @(
        $Document.PSObject.Properties | ForEach-Object { [string]$_.Name }
    )
    if ($Properties.Count -ne 3 -or
        $Properties -cnotcontains 'schema' -or
        $Properties -cnotcontains 'runtimeId' -or
        $Properties -cnotcontains 'tools' -or
        [string]$Document.schema -cne $script:ProjCommandRuntimeSchema -or
        [string]$Document.runtimeId -cne $RuntimeId) {
        throw 'The Command Runtime manifest identity is invalid.'
    }
    $Tools = [object[]]@($Document.tools)
    $Names = [string[]]@($Tools | ForEach-Object { [string]$_.name })
    if ($Tools.Count -ne 2 -or
        $Names -cnotcontains 'bun' -or
        $Names -cnotcontains 'pwsh' -or
        (Get-ProjCommandRuntimeId -Tools $Tools) -cne $RuntimeId) {
        throw 'The Command Runtime tool set is invalid.'
    }
    foreach ($Tool in $Tools) {
        [string[]]$ToolProperties = @(
            $Tool.PSObject.Properties | ForEach-Object { [string]$_.Name }
        )
        if ($ToolProperties.Count -ne 5 -or
            $ToolProperties -cnotcontains 'name' -or
            $ToolProperties -cnotcontains 'version' -or
            $ToolProperties -cnotcontains 'path' -or
            $ToolProperties -cnotcontains 'length' -or
            $ToolProperties -cnotcontains 'sha256' -or
            [string]$Tool.version -cnotmatch '^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$' -or
            [string]$Tool.path -cnotmatch '^[A-Za-z0-9._+-]+(?:/[A-Za-z0-9._+ -]+)*$' -or
            [long]$Tool.length -le 0 -or
            [long]$Tool.length -gt $script:ProjCommandRuntimeMaxToolBytes -or
            [string]$Tool.sha256 -cnotmatch '^[a-f0-9]{64}$') {
            throw "The Command Runtime tool record is invalid: $($Tool.name)"
        }
        $ToolPath = Join-Path $BootstrapDataRoot (
            ([string]$Tool.path).Replace('/', '\')
        )
        $ToolPath = Assert-ProjDevPathInsideDataRoot `
            -Path $ToolPath `
            -DataRoot $BootstrapDataRoot `
            -Activity "reading the $($Tool.name) Command Runtime"
        $Item = Get-Item -LiteralPath $ToolPath -Force -ErrorAction Stop
        if (-not [IO.File]::Exists($ToolPath) -or
            $Item.Length -ne [long]$Tool.length -or
            ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            (Get-ProjDevFileSha256 -Path $ToolPath) -cne [string]$Tool.sha256) {
            throw "The Command Runtime tool is corrupt: $ToolPath"
        }
    }
    return [pscustomobject][ordered]@{
        RuntimeId = $RuntimeId
        Root = $Root
        Tools = $Tools
    }
}
