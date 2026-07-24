Set-StrictMode -Version 2.0

function Get-XvenvToolsReport {
    param([Parameter(Mandatory = $true)][object]$Catalog)

    $Tools = [Collections.Generic.List[object]]::new()
    foreach ($Name in [string[]]$Catalog.PublicOrder) {
        $Definition = $Catalog.Tools[$Name]
        [void]$Tools.Add([pscustomobject][ordered]@{
            name = [string]$Definition.Name
            defaultVersion = [string]$Definition.Version
            requires = [string[]]@($Definition.Requires)
        })
    }
    return [pscustomobject][ordered]@{
        schema = 'xvenv.tools.v1'
        tools = [object[]]$Tools.ToArray()
    }
}

function Invoke-XvenvTools {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [switch]$Json
    )

    $Report = Get-XvenvToolsReport -Catalog $Context.Catalog
    if ($Json) {
        Write-XvenvJsonOutput -Value $Report
        return 0
    }

    $Table = $Report.tools |
        Select-Object `
            @{ Name = 'Tool'; Expression = { $_.name } },
            @{ Name = 'Default version'; Expression = { $_.defaultVersion } },
            @{ Name = 'Requires'; Expression = {
                [string]::Join(', ', [string[]]$_.requires)
            } } |
        Format-Table -AutoSize |
        Out-String -Width 4096
    Write-Host $Table.TrimEnd()
    return 0
}
