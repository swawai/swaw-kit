Set-StrictMode -Version 2.0

function New-XvenvDesiredPlan {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][string[]]$ToolNames
    )

    if ($ToolNames.Count -eq 0) {
        throw "Usage: $(Get-XvenvSetCommandExample $Context.Catalog)"
    }

    $Selected = @{}
    foreach ($RawName in $ToolNames) {
        $Name = ([string]$RawName).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($Name) -or
            -not $Context.Catalog.Tools.ContainsKey($Name)) {
            $Supported = [string]::Join(', ', [string[]]$Context.Catalog.PublicOrder)
            throw "Unsupported xvenv tool '$RawName'. Supported tools: $Supported"
        }
        $Selected[$Name] = $true
    }

    $Tools = [Collections.Generic.List[object]]::new()
    $Definitions = [Collections.Generic.List[object]]::new()
    foreach ($Name in [string[]]$Context.Catalog.PublicOrder) {
        if (-not $Selected.ContainsKey($Name)) {
            continue
        }
        $Definition = Get-XvenvCatalogEntry -Catalog $Context.Catalog -Name $Name
        [void]$Tools.Add((New-XvenvConfiguredEntry $Definition))
        [void]$Definitions.Add($Definition)
    }

    $Components = [Collections.Generic.List[object]]::new()
    foreach ($Name in Get-XvenvRequiredComponentNames `
        -Catalog $Context.Catalog `
        -Definitions $Definitions.ToArray()) {
        $Definition = Get-XvenvCatalogEntry `
            -Catalog $Context.Catalog `
            -Name $Name `
            -Component
        [void]$Components.Add((New-XvenvConfiguredEntry $Definition))
    }

    return [pscustomobject]@{
        schema = 'xvenv.plan.v1'
        projectRoot = $Context.ProjectRoot
        tools = $Tools.ToArray()
        components = $Components.ToArray()
        variables = [ordered]@{}
        pathPrefixes = [Collections.Generic.List[string]]::new()
        shell = $null
    }
}

function Set-XvenvPlanVariable {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][string]$Value
    )

    if ($Name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        throw "Invalid generated environment variable name: $Name"
    }
    if ($Plan.variables.Contains($Name)) {
        throw "Generated environment variable '$Name' is declared more than once."
    }
    $Plan.variables[$Name] = $Value
}

function Add-XvenvPlanPath {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }
    foreach ($Existing in $Plan.pathPrefixes) {
        if ($Existing.Equals($Path, [StringComparison]::OrdinalIgnoreCase)) {
            return
        }
    }
    [void]$Plan.pathPrefixes.Add($Path)
}

function Set-XvenvPlanShell {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Executable
    )

    $Plan.shell = [pscustomobject]@{
        kind = $Kind
        executable = $Executable
    }
}

function ConvertTo-XvenvEntryList {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Entries
    )

    $Parts = [Collections.Generic.List[string]]::new()
    foreach ($Entry in $Entries) {
        $Sha256 = if ($Entry -is [Collections.IDictionary] -and $Entry.Contains('sha256')) {
            [string]$Entry['sha256']
        } elseif ($null -ne $Entry.PSObject.Properties['sha256']) {
            [string]$Entry.sha256
        } else {
            ''
        }
        [void]$Parts.Add("$($Entry.name)|$($Entry.version)|$Sha256")
    }
    return [string]::Join(';', $Parts.ToArray())
}

function Complete-XvenvEnvironmentPlan {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Plan
    )

    Set-XvenvPlanVariable $Plan 'XVENV_PROJECT_ROOT' $Context.ProjectRoot
    Set-XvenvPlanVariable $Plan 'XVENV_ENV_ROOT' $Context.ProjectDataRoot
    Set-XvenvPlanVariable $Plan 'XVENV_TOOLS' (ConvertTo-XvenvEntryList @($Plan.tools))
    Set-XvenvPlanVariable $Plan 'XVENV_COMPONENTS' (ConvertTo-XvenvEntryList @($Plan.components))

    foreach ($Entry in @($Plan.tools)) {
        $Definition = Get-XvenvConfiguredDefinition -Context $Context -Entry $Entry
        $Dependencies = Get-XvenvConfiguredDependencies `
            -Context $Context `
            -Plan $Plan `
            -Definition $Definition
        $Contribute = [scriptblock]$Definition._Handlers.ContributeEnvironment
        [void](& $Contribute $Context $Definition $Plan $Dependencies)
    }

    if ($null -eq $Plan.shell) {
        Set-XvenvPlanShell `
            -Plan $Plan `
            -Kind 'cmd' `
            -Executable (Join-Path $env:SystemRoot 'System32\cmd.exe')
    }
    Set-XvenvPlanVariable $Plan 'XVENV_SHELL_KIND' ([string]$Plan.shell.kind)
    Set-XvenvPlanVariable $Plan 'XVENV_SHELL_EXE' ([string]$Plan.shell.executable)
    return $Plan
}
