if ($args.Count -ne 0) {
    throw "Command '.info' does not accept tail arguments."
}

$Rows = [ordered]@{
    command = $env:SWAWKIT_COMMAND_ADDRESS
    commandDirectory = $env:SWAWKIT_COMMAND_DIR
    entryName = $env:SWAWKIT_PROJ_ENTRY_COMMAND
    entryFile = $env:SWAWKIT_PROJ_ENTRY_FILE
    projHome = $env:SWAWKIT_PROJ_HOME
    projectRoot = $env:SWAWKIT_PROJ_DIR
    actionRoot = $env:SWAWKIT_PROJ_ACTION_ROOT
    dataRoot = $env:SWAWKIT_PROJ_DATA_ROOT
    cacheRoot = Join-Path $env:SWAWKIT_PROJ_HOME 'data\proj_cache'
    invocationDirectory = $env:SWAWKIT_INVOCATION_DIR
}

foreach ($Name in $Rows.Keys) {
    $Value = if ($null -eq $Rows[$Name]) { '' } else { [string]$Rows[$Name] }
    Write-Host ("{0,-20} {1}" -f $Name, $Value)
}
