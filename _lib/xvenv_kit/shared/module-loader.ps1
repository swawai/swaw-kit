Set-StrictMode -Version 2.0

function Assert-XvenvModuleDefinition {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Definition,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    if ([string]$Definition.Schema -ne 'xvenv.module.v1') {
        throw "Unsupported xvenv module schema in '$ManifestPath': $($Definition.Schema)"
    }

    $AllowedKeys = @(
        'Schema',
        'Name',
        'Public',
        'Order',
        'Version',
        'Url',
        'UrlTemplate',
        'Hashes',
        'ArchiveSubdir',
        'RequiredPaths',
        'Requires'
    )
    foreach ($Key in $Definition.Keys) {
        if ($AllowedKeys -notcontains [string]$Key) {
            throw "Unknown xvenv module field '$Key' in '$ManifestPath'."
        }
    }

    $Name = ([string]$Definition.Name).Trim().ToLowerInvariant()
    if ($Name -notmatch '^[a-z][a-z0-9-]*$') {
        throw "Invalid xvenv module name in '$ManifestPath': $($Definition.Name)"
    }
    if (-not $Definition.ContainsKey('Public') -or $Definition.Public -isnot [bool]) {
        throw "The xvenv module '$Name' must declare Public as a Boolean."
    }
    if (-not $Definition.ContainsKey('Order')) {
        throw "The xvenv module '$Name' must declare Order."
    }
    try {
        [void][int]$Definition.Order
    } catch {
        throw "The xvenv module '$Name' has an invalid Order."
    }
    if ([string]::IsNullOrWhiteSpace([string]$Definition.Version)) {
        throw "The xvenv module '$Name' must declare Version."
    }
    if (-not $Definition.ContainsKey('RequiredPaths') -or
        @($Definition.RequiredPaths).Count -eq 0) {
        throw "The xvenv module '$Name' must declare RequiredPaths."
    }
    foreach ($RelativePath in [string[]]@($Definition.RequiredPaths)) {
        if ([string]::IsNullOrWhiteSpace($RelativePath) -or
            [IO.Path]::IsPathRooted($RelativePath) -or
            $RelativePath -match '(^|[\\/])\.\.([\\/]|$)') {
            throw "The xvenv module '$Name' has an unsafe RequiredPaths entry: $RelativePath"
        }
    }

    foreach ($ListName in @('Requires')) {
        if (-not $Definition.ContainsKey($ListName)) {
            throw "The xvenv module '$Name' must declare $ListName."
        }
    }

    $NormalizedRequires = [Collections.Generic.List[string]]::new()
    foreach ($DependencyName in [string[]]@($Definition.Requires)) {
        $DependencyName = $DependencyName.Trim().ToLowerInvariant()
        if ($DependencyName -notmatch '^[a-z][a-z0-9-]*$') {
            throw "The xvenv module '$Name' has an invalid dependency name: $DependencyName"
        }
        if (-not $NormalizedRequires.Contains($DependencyName)) {
            [void]$NormalizedRequires.Add($DependencyName)
        }
    }
    $Definition.Requires = $NormalizedRequires.ToArray()
    if (-not [bool]$Definition.Public -and $Definition.Requires.Count -gt 0) {
        throw "The internal xvenv module '$Name' cannot require another module."
    }

    $HasUrl = $Definition.ContainsKey('Url')
    $HasHashes = $Definition.ContainsKey('Hashes')
    if ($HasUrl -xor $HasHashes) {
        throw "The xvenv module '$Name' must declare Url and Hashes together."
    }
    if ($HasUrl) {
        if ([string]::IsNullOrWhiteSpace([string]$Definition.Url) -or
            $Definition.Hashes -isnot [hashtable] -or
            -not $Definition.Hashes.ContainsKey([string]$Definition.Version) -or
            [string]$Definition.Hashes[[string]$Definition.Version] -notmatch '^[A-Fa-f0-9]{64}$') {
            throw "The xvenv module '$Name' must pin a valid SHA-256 for its default version."
        }
        if (-not $Definition.ContainsKey('ArchiveSubdir')) {
            throw "The xvenv module '$Name' must declare ArchiveSubdir."
        }
        if (-not $Definition.ContainsKey('UrlTemplate') -or
            [string]$Definition.UrlTemplate -notlike '*{version}*') {
            throw "The xvenv module '$Name' must declare a UrlTemplate containing '{version}'."
        }
        $ArchiveSubdir = [string]$Definition.ArchiveSubdir
        if (-not [string]::IsNullOrWhiteSpace($ArchiveSubdir) -and
            ([IO.Path]::IsPathRooted($ArchiveSubdir) -or
             $ArchiveSubdir -match '(^|[\\/])\.\.([\\/]|$)')) {
            throw "The xvenv module '$Name' has an unsafe ArchiveSubdir: $ArchiveSubdir"
        }
    }
}

function Assert-XvenvModuleHandlers {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Handlers,
        [Parameter(Mandatory = $true)][hashtable]$Definition,
        [Parameter(Mandatory = $true)][string]$ScriptPath
    )

    $ExpectedName = [string]$Definition.Name
    $AllowedKeys = @('Name', 'Install', 'Validate', 'ContributeEnvironment')
    foreach ($Key in $Handlers.Keys) {
        if ($AllowedKeys -notcontains [string]$Key) {
            throw "Unknown xvenv module handler '$Key' in '$ScriptPath'."
        }
    }
    if (-not ([string]$Handlers.Name).Equals($ExpectedName, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The xvenv module script '$ScriptPath' returned handlers for '$($Handlers.Name)', expected '$ExpectedName'."
    }
    if (-not $Handlers.ContainsKey('Install') -or $Handlers.Install -isnot [scriptblock]) {
        throw "The xvenv module '$ExpectedName' must provide an Install callback."
    }
    foreach ($OptionalCallback in @('Validate', 'ContributeEnvironment')) {
        if ($Handlers.ContainsKey($OptionalCallback) -and
            $null -ne $Handlers[$OptionalCallback] -and
            $Handlers[$OptionalCallback] -isnot [scriptblock]) {
            throw "The xvenv module '$ExpectedName' callback '$OptionalCallback' must be a script block."
        }
    }
    if ([bool]$Definition.Public -and
        (-not $Handlers.ContainsKey('ContributeEnvironment') -or
         $Handlers.ContributeEnvironment -isnot [scriptblock])) {
        throw "The public xvenv module '$ExpectedName' must provide a ContributeEnvironment callback."
    }
    if (-not [bool]$Definition.Public -and
        $Handlers.ContainsKey('ContributeEnvironment')) {
        throw "The internal xvenv module '$ExpectedName' cannot provide a ContributeEnvironment callback."
    }
}

function Import-XvenvModuleCatalog {
    param([Parameter(Mandatory = $true)][string]$ModuleRoot)

    # This loader is for trusted modules shipped with swaw-kit.
    # Project directories and third-party plugin roots must never be passed here.
    $Root = Get-XvenvFullPath $ModuleRoot
    if (-not [IO.Directory]::Exists($Root)) {
        throw "xvenv module root is missing: $Root"
    }

    $Records = [Collections.Generic.List[object]]::new()
    $DefinitionsByName = @{}
    foreach ($Directory in @(Get-ChildItem -LiteralPath $Root -Directory)) {
        $ManifestPath = Join-Path $Directory.FullName 'module.psd1'
        $ScriptPath = Join-Path $Directory.FullName 'module.ps1'
        if (-not [IO.File]::Exists($ManifestPath)) {
            throw "xvenv module manifest is missing: $ManifestPath"
        }
        if (-not [IO.File]::Exists($ScriptPath)) {
            throw "xvenv module script is missing: $ScriptPath"
        }

        $Imported = Import-PowerShellDataFile -LiteralPath $ManifestPath
        if ($Imported -isnot [hashtable]) {
            throw "The xvenv module manifest must return a hashtable: $ManifestPath"
        }
        $Definition = @{}
        foreach ($Key in $Imported.Keys) {
            $Definition[$Key] = $Imported[$Key]
        }
        Assert-XvenvModuleDefinition -Definition $Definition -ManifestPath $ManifestPath
        $Name = ([string]$Definition.Name).ToLowerInvariant()
        if ($DefinitionsByName.ContainsKey($Name)) {
            throw "Duplicate xvenv module name '$Name' in '$ManifestPath'."
        }
        $Definition.Name = $Name
        $Definition.Order = [int]$Definition.Order
        $DefinitionsByName[$Name] = $Definition
        [void]$Records.Add([pscustomobject]@{
            Name = $Name
            Directory = $Directory.FullName
            ScriptPath = $ScriptPath
            Definition = $Definition
        })
    }

    foreach ($Record in $Records) {
        foreach ($DependencyName in [string[]]@($Record.Definition.Requires)) {
            $NormalizedDependency = $DependencyName.Trim().ToLowerInvariant()
            if (-not $DefinitionsByName.ContainsKey($NormalizedDependency)) {
                throw "The xvenv module '$($Record.Name)' requires missing module '$DependencyName'."
            }
            if ([bool]$DefinitionsByName[$NormalizedDependency].Public) {
                throw "The xvenv module '$($Record.Name)' may only require an internal module, not '$DependencyName'."
            }
        }
    }
    if ($Records.Count -eq 0) {
        throw "xvenv module root contains no modules: $Root"
    }

    $OrderedRecords = @($Records | Sort-Object `
        @{ Expression = { [int]$_.Definition.Order } }, `
        @{ Expression = { [string]$_.Name } })

    $Tools = @{}
    $Components = @{}
    $PublicOrder = [Collections.Generic.List[string]]::new()
    $ComponentOrder = [Collections.Generic.List[string]]::new()

    foreach ($Record in $OrderedRecords) {
        $HandlerOutput = @(& $Record.ScriptPath)
        if ($HandlerOutput.Count -ne 1 -or $HandlerOutput[0] -isnot [hashtable]) {
            throw "The xvenv module script must return exactly one handler hashtable: $($Record.ScriptPath)"
        }
        $Handlers = [hashtable]$HandlerOutput[0]
        Assert-XvenvModuleHandlers `
            -Handlers $Handlers `
            -Definition $Record.Definition `
            -ScriptPath $Record.ScriptPath

        $Record.Definition._Handlers = $Handlers
        if ([bool]$Record.Definition.Public) {
            $Tools[$Record.Name] = $Record.Definition
            [void]$PublicOrder.Add($Record.Name)
        } else {
            $Components[$Record.Name] = $Record.Definition
            [void]$ComponentOrder.Add($Record.Name)
        }
    }

    return @{
        Schema = 'xvenv.catalog.v1'
        PublicOrder = $PublicOrder.ToArray()
        ComponentOrder = $ComponentOrder.ToArray()
        Tools = $Tools
        Components = $Components
    }
}
