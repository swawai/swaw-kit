Set-StrictMode -Version 2.0

function Get-XvenvStatusReport {
    param([Parameter(Mandatory = $true)][object]$Context)

    $HasCmd = [IO.File]::Exists($Context.EnvCmdPath)
    $HasPs1 = [IO.File]::Exists($Context.EnvPs1Path)
    if (-not $HasCmd -and -not $HasPs1) {
        return [pscustomobject][ordered]@{
            schema = 'xvenv.status.v1'
            projectRoot = [string]$Context.ProjectRoot
            environmentRoot = [string]$Context.ProjectDataRoot
            configPath = ''
            configured = $false
            ready = $false
            tools = [object[]]@()
        }
    }

    $Plan = Import-XvenvGeneratedEnvironment -Context $Context
    $Statuses = @(Get-XvenvPlanStatuses -Context $Context -Plan $Plan)
    $Tools = foreach ($Status in $Statuses) {
        [pscustomobject][ordered]@{
            name = [string]$Status.Tool
            version = [string]$Status.Version
            ready = [bool]$Status.Ready
            path = [string]$Status.Path
            details = [string]$Status.Details
        }
    }
    $Ready = @($Statuses | Where-Object { -not $_.Ready }).Count -eq 0
    return [pscustomobject][ordered]@{
        schema = 'xvenv.status.v1'
        projectRoot = [string]$Context.ProjectRoot
        environmentRoot = [string]$Context.ProjectDataRoot
        configPath = [string]$Context.EnvPs1Path
        configured = $true
        ready = $Ready
        tools = [object[]]@($Tools)
    }
}

function Invoke-XvenvStatus {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [switch]$Json
    )

    $Report = Get-XvenvStatusReport -Context $Context
    if ($Json) {
        Write-XvenvJsonOutput -Value $Report
        return 0
    }

    Write-Host "Project : $($Report.projectRoot)"
    Write-Host "Data    : $($Report.environmentRoot)"
    if (-not $Report.configured) {
        Write-Host 'Config  : not configured' -ForegroundColor Yellow
        Write-Host "Run: $(Get-XvenvSetCommandExample $Context.Catalog)"
        return 0
    }

    Write-Host "Config  : $($Report.configPath)"
    $Table = $Report.tools |
        Select-Object `
            @{ Name = 'Tool'; Expression = { $_.name } },
            @{ Name = 'Version'; Expression = { $_.version } },
            @{ Name = 'State'; Expression = {
                if ($_.ready) { 'ready' } else { 'missing' }
            } },
            @{ Name = 'Path'; Expression = { $_.path } },
            @{ Name = 'Details'; Expression = { $_.details } } |
        Format-Table -AutoSize |
        Out-String -Width 4096
    Write-Host $Table.TrimEnd()

    if (-not $Report.ready) {
        Write-Host 'Environment is incomplete. Run xvenv set with the desired tools.' -ForegroundColor Yellow
    } else {
        Write-Host 'Environment is ready.' -ForegroundColor Green
    }
    return 0
}
