Set-StrictMode -Version 2.0

function Get-XvenvSetCommandExample {
    param([Parameter(Mandatory = $true)][object]$Catalog)

    return "xvenv set $([string]::Join(' ', [string[]]$Catalog.PublicOrder))"
}

function Get-XvenvCatalogEntry {
    param(
        [Parameter(Mandatory = $true)][object]$Catalog,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$Component
    )

    $Collection = if ($Component) { $Catalog.Components } else { $Catalog.Tools }
    if (-not $Collection.ContainsKey($Name)) {
        $Kind = if ($Component) { 'component' } else { 'tool' }
        throw "Unsupported xvenv $Kind '$Name'."
    }
    return $Collection[$Name]
}

function Get-XvenvExpectedSha256 {
    param([Parameter(Mandatory = $true)][object]$Definition)

    $Expected = ([string]$Definition.Sha256).ToLowerInvariant()
    if ($Expected -notmatch '^[a-f0-9]{64}$') {
        throw "No trusted SHA-256 is available for $($Definition.Name) $($Definition.Version)."
    }
    return $Expected
}

function Copy-XvenvDefinitionWithVersion {
    param(
        [Parameter(Mandatory = $true)][object]$Definition,
        [Parameter(Mandatory = $true)][string]$Version,
        [AllowNull()][string]$Sha256 = $null
    )

    $Copy = @{}
    foreach ($Key in $Definition.Keys) {
        $Copy[$Key] = $Definition[$Key]
    }
    $ResolvedVersion = Get-XvenvSafeSegment -Value $Version -Description 'version'
    if ($ResolvedVersion -ne [string]$Definition.Version -and
        $Definition.ContainsKey('UrlTemplate') -and
        -not [string]::IsNullOrWhiteSpace([string]$Definition.UrlTemplate)) {
        $Copy.Url = ([string]$Definition.UrlTemplate).Replace('{version}', $ResolvedVersion)
    }
    if (-not [string]::IsNullOrWhiteSpace($Sha256)) {
        if ($Sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
            throw "Invalid SHA-256 for $($Definition.Name) $ResolvedVersion."
        }
        $Copy.Sha256 = $Sha256.ToLowerInvariant()
    } elseif ($Definition.ContainsKey('Hashes') -and
        $Definition.Hashes.ContainsKey($ResolvedVersion)) {
        $Copy.Sha256 = [string]$Definition.Hashes[$ResolvedVersion]
    } else {
        [void]$Copy.Remove('Sha256')
    }
    $Copy.Version = $ResolvedVersion
    return $Copy
}

function Test-XvenvDefinitionHasArtifact {
    param([Parameter(Mandatory = $true)][object]$Definition)

    return $Definition.ContainsKey('Url') -and
        $Definition.ContainsKey('Hashes') -and
        -not [string]::IsNullOrWhiteSpace([string]$Definition.Url)
}

function New-XvenvConfiguredEntry {
    param([Parameter(Mandatory = $true)][object]$Definition)

    $Entry = [ordered]@{
        name = [string]$Definition.Name
        version = [string]$Definition.Version
    }
    if (Test-XvenvDefinitionHasArtifact $Definition) {
        $Resolved = Copy-XvenvDefinitionWithVersion `
            -Definition $Definition `
            -Version ([string]$Definition.Version)
        $Entry.sha256 = Get-XvenvExpectedSha256 $Resolved
    }
    return $Entry
}

function Get-XvenvRequiredComponentNames {
    param(
        [Parameter(Mandatory = $true)][object]$Catalog,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Definitions
    )

    $Required = @{}
    foreach ($Definition in $Definitions) {
        foreach ($Name in [string[]]@($Definition.Requires)) {
            $Required[$Name.ToLowerInvariant()] = $true
        }
    }
    $Ordered = [Collections.Generic.List[string]]::new()
    foreach ($Name in [string[]]$Catalog.ComponentOrder) {
        if ($Required.ContainsKey($Name)) {
            [void]$Ordered.Add($Name)
        }
    }
    return $Ordered.ToArray()
}

function Get-XvenvPlanEntry {
    param(
        [Parameter(Mandatory = $true)][object[]]$Entries,
        [Parameter(Mandatory = $true)][string]$Name
    )

    foreach ($Entry in $Entries) {
        if (([string]$Entry.name).Equals($Name, [StringComparison]::OrdinalIgnoreCase)) {
            return $Entry
        }
    }
    return $null
}

function Get-XvenvConfiguredDefinition {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Entry,
        [switch]$Component
    )

    $Name = ([string]$Entry.name).ToLowerInvariant()
    $Definition = Get-XvenvCatalogEntry `
        -Catalog $Context.Catalog `
        -Name $Name `
        -Component:$Component
    $Sha256 = if ($Entry -is [Collections.IDictionary] -and
        $Entry.Contains('sha256')) {
        [string]$Entry['sha256']
    } elseif ($null -ne $Entry.PSObject.Properties['sha256']) {
        [string]$Entry.sha256
    } else {
        $null
    }
    return Copy-XvenvDefinitionWithVersion `
        -Definition $Definition `
        -Version ([string]$Entry.version) `
        -Sha256 $Sha256
}

function Get-XvenvConfiguredDependencies {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][object]$Definition
    )

    $Dependencies = @{}
    foreach ($Name in [string[]]@($Definition.Requires)) {
        $Entry = Get-XvenvPlanEntry -Entries @($Plan.components) -Name $Name
        if ($null -eq $Entry) {
            throw "The xvenv module '$($Definition.Name)' requires '$Name'."
        }
        $Dependencies[$Name] = Get-XvenvConfiguredDefinition `
            -Context $Context `
            -Entry $Entry `
            -Component
    }
    return $Dependencies
}
