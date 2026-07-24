Set-StrictMode -Version 2.0

function Invoke-XvenvModuleInstall {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][object]$Definition
    )

    $Dependencies = Get-XvenvConfiguredDependencies `
        -Context $Context `
        -Plan $Plan `
        -Definition $Definition
    $Install = [scriptblock]$Definition._Handlers.Install
    [void](& $Install $Context $Definition $Plan $Dependencies)
}

function Install-XvenvPlan {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Plan
    )

    $InstalledComponents = @{}
    foreach ($Entry in @($Plan.tools)) {
        $Definition = Get-XvenvConfiguredDefinition -Context $Context -Entry $Entry
        foreach ($Name in [string[]]@($Definition.Requires)) {
            if ($InstalledComponents.ContainsKey($Name)) {
                continue
            }
            $ComponentEntry = Get-XvenvPlanEntry -Entries @($Plan.components) -Name $Name
            $Component = Get-XvenvConfiguredDefinition `
                -Context $Context `
                -Entry $ComponentEntry `
                -Component
            Invoke-XvenvModuleInstall `
                -Context $Context `
                -Plan $Plan `
                -Definition $Component
            $InstalledComponents[$Name] = $true
        }
        Invoke-XvenvModuleInstall `
            -Context $Context `
            -Plan $Plan `
            -Definition $Definition
    }
}

function Invoke-XvenvSet {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][string[]]$ToolNames
    )

    Assert-XvenvNotActive
    # Validate the full target set before creating locks or data.
    [void](New-XvenvDesiredPlan -Context $Context -ToolNames $ToolNames)

    $LockPath = Join-Path (Join-Path $Context.DataRoot 'locks\projects') "$($Context.ProjectId).lock"
    $Lock = Enter-XvenvFileLock -Path $LockPath
    try {
        $Plan = New-XvenvDesiredPlan -Context $Context -ToolNames $ToolNames
        Install-XvenvPlan -Context $Context -Plan $Plan
        Assert-XvenvPlanInstalled -Context $Context -Plan $Plan
        [void](Complete-XvenvEnvironmentPlan -Context $Context -Plan $Plan)
        $Scripts = ConvertTo-XvenvEnvironmentScripts -Plan $Plan
        $Changed = Publish-XvenvEnvironmentScripts `
            -Context $Context `
            -Scripts $Scripts
        if ($Changed) {
            Write-Host "xvenv configured: $([string]::Join(', ', [string[]]@($Plan.tools | ForEach-Object { $_.name })))" -ForegroundColor Green
        } else {
            Write-Host 'xvenv configuration is already up to date.' -ForegroundColor Green
        }
    } finally {
        $Lock.Dispose()
    }
    return 0
}
