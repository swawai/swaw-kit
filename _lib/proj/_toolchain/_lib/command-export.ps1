Set-StrictMode -Version 2.0

function Get-ProjSystemCommandDataRoot {
    param(
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$Address
    )

    if ($Address -cnotmatch '^\.[a-z][a-z0-9-]*(?:/[a-z][a-z0-9-]*)*$') {
        throw "Invalid System command provider address: '$Address'"
    }
    $Path = Join-Path $DataRoot 'modules\system'
    foreach ($Segment in $Address.Substring(1).Split('/')) {
        $Path = Join-Path $Path $Segment
    }
    return Assert-ProjDevPathInsideDataRoot `
        -Path $Path `
        -DataRoot $DataRoot `
        -Activity "resolving command data for '$Address'"
}

function Get-ProjModuleCommandDataRoot {
    param(
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$Address
    )

    if ($Address -cnotmatch '^[a-z][a-z0-9-]*(?:/[a-z][a-z0-9-]*)*$' -or
        $Address.Split('/')[0] -cin @('system', 'module')) {
        throw "Invalid Module command provider address: '$Address'"
    }
    $Path = Join-Path $DataRoot 'modules'
    foreach ($Segment in $Address.Split('/')) {
        $Path = Join-Path $Path $Segment
    }
    return Assert-ProjDevPathInsideDataRoot `
        -Path $Path `
        -DataRoot $DataRoot `
        -Activity "resolving command data for '$Address'"
}

function Get-ProjCommandProviderDataRoot {
    param(
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$ProviderAddress,
        [ValidateSet('system', 'module')]
        [string]$ProviderSpace = 'system'
    )

    if ($ProviderSpace -ceq 'module') {
        return Get-ProjModuleCommandDataRoot `
            -DataRoot $DataRoot `
            -Address $ProviderAddress
    }
    return Get-ProjSystemCommandDataRoot `
        -DataRoot $DataRoot `
        -Address $ProviderAddress
}

function Resolve-ProjCommandExportPath {
    param(
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$ProviderAddress,
        [ValidateSet('system', 'module')]
        [string]$ProviderSpace = 'system'
    )

    $CommandRoot = Get-ProjCommandProviderDataRoot `
        -DataRoot $DataRoot `
        -ProviderAddress $ProviderAddress `
        -ProviderSpace $ProviderSpace
    return Assert-ProjDevPathInsideDataRoot `
        -Path (Join-Path $CommandRoot 'export') `
        -DataRoot $DataRoot `
        -Activity "resolving the '$ProviderAddress' command export"
}

function Get-ProjReadyCommandExport {
    param(
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$ProviderAddress,
        [Parameter(Mandatory = $true)][string]$EntryCommand,
        [Parameter(Mandatory = $true)][string]$ExportId,
        [Parameter(Mandatory = $true)][string]$ProducerContract,
        [ValidateSet('system', 'module')]
        [string]$ProviderSpace = 'system'
    )

    if ($ExportId -cnotmatch '^[a-z][a-z0-9-]{0,31}$') {
        throw "Invalid command provider export id: '$ExportId'"
    }
    if ($ProducerContract -cnotmatch '^[a-z0-9][a-z0-9._/-]{0,127}$') {
        throw "Invalid command provider contract: '$ProducerContract'"
    }
    $CommandRoot = Get-ProjCommandProviderDataRoot `
        -DataRoot $DataRoot `
        -ProviderAddress $ProviderAddress `
        -ProviderSpace $ProviderSpace
    $ExportRoot = Resolve-ProjCommandExportPath `
        -DataRoot $DataRoot `
        -ProviderAddress $ProviderAddress `
        -ProviderSpace $ProviderSpace
    $StatePath = Assert-ProjDevPathInsideDataRoot `
        -Path (Join-Path $CommandRoot '_state.json') `
        -DataRoot $DataRoot `
        -Activity "resolving the '$ProviderAddress' provider state"
    try {
        $State = Read-ProjCommandProviderState `
            -Path $StatePath `
            -DataRoot $DataRoot
    } catch {
        $State = $null
    }
    $MatchingExport = if ($null -eq $State -or
        [string]$State.Status -cne 'ready') {
        $null
    } else {
        @($State.Exports | Where-Object {
            [string]$_.Id -ceq $ExportId -and
            [string]$_.Contract -ceq $ProducerContract
        })
    }
    if ($null -eq $State -or
        [string]$State.Status -cne 'ready' -or
        @($MatchingExport).Count -ne 1 -or
        -not [IO.Directory]::Exists($ExportRoot)) {
        throw (
            "Required export from '$ProviderAddress' is unavailable or " +
            "outdated. Run '$EntryCommand $ProviderAddress'."
        )
    }
    return [pscustomobject][ordered]@{
        ProviderAddress = $ProviderAddress
        ProviderSpace = $ProviderSpace
        ExportId = $ExportId
        CommandRoot = $CommandRoot
        ExportRoot = $ExportRoot
        StatePath = $StatePath
        InputRevision = [string]$State.InputRevision
        Token = [string]$State.Token
        ProducerContract = $ProducerContract
    }
}

function Get-ProjRequiredCommandExport {
    param(
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$ProviderAddress,
        [Parameter(Mandatory = $true)][string]$EntryCommand,
        [Parameter(Mandatory = $true)][string]$InputRevision,
        [Parameter(Mandatory = $true)][string]$ExportId,
        [Parameter(Mandatory = $true)][string]$ProducerContract,
        [ValidateSet('system', 'module')]
        [string]$ProviderSpace = 'system'
    )

    [void](Assert-ProjCommandProviderInputRevision `
        -InputRevision $InputRevision)
    $Publication = Get-ProjReadyCommandExport `
        -DataRoot $DataRoot `
        -ProviderAddress $ProviderAddress `
        -EntryCommand $EntryCommand `
        -ExportId $ExportId `
        -ProducerContract $ProducerContract `
        -ProviderSpace $ProviderSpace
    if ([string]$Publication.InputRevision -cne $InputRevision) {
        throw (
            "Required export from '$ProviderAddress' is unavailable or " +
            'outdated. Run ' +
            "'$EntryCommand $ProviderAddress'."
        )
    }
    return $Publication
}

function Assert-ProjCommandProviderPublicationCurrent {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Publication
    )

    try {
        $State = Read-ProjCommandProviderState `
            -Path ([string]$Context.ProviderStatePath) `
            -DataRoot ([string]$Context.DataRoot)
    } catch {
        $State = $null
    }
    $MatchingExport = if ($null -eq $State -or
        [string]$State.Status -cne 'ready') {
        $null
    } else {
        @($State.Exports | Where-Object {
            [string]$_.Id -ceq [string]$Publication.ExportId -and
            [string]$_.Contract -ceq [string]$Publication.ProducerContract
        })
    }
    if ($null -eq $State -or
        [string]$State.Status -cne 'ready' -or
        [string]$State.InputRevision -cne [string]$Publication.InputRevision -or
        [string]$State.Token -cne [string]$Publication.Token -or
        @($MatchingExport).Count -ne 1) {
        $Repair = Get-ProjEnvironmentRepairInvocation -Context $Context
        throw (
            'The development environment publication changed while it was ' +
            "being loaded. Run '$Repair'."
        )
    }
}

function Get-ProjProviderInvocation {
    param(
        [Parameter(Mandatory = $true)][string]$EntryCommand,
        [Parameter(Mandatory = $true)][string]$ProviderAddress
    )

    return "$EntryCommand $ProviderAddress"
}

function Get-ProjEnvironmentRepairInvocation {
    param([Parameter(Mandatory = $true)][object]$Context)

    $Override = $Context.PSObject.Properties['EnvironmentRepairInvocation']
    if ($null -ne $Override -and
        -not [string]::IsNullOrWhiteSpace([string]$Override.Value)) {
        return [string]$Override.Value
    }
    $Provider = $Context.PSObject.Properties['EnvironmentProviderAddress']
    if ($null -eq $Provider -or
        [string]::IsNullOrWhiteSpace([string]$Provider.Value)) {
        throw 'The development environment provider address is missing.'
    }
    return Get-ProjProviderInvocation `
        -EntryCommand ([string]$Context.EntryCommand) `
        -ProviderAddress ([string]$Provider.Value)
}
