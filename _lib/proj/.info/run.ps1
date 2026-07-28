if ($args.Count -ne 0) {
    throw "Command '.info' does not accept tail arguments."
}

$Rows = [ordered]@{
    command = $env:SWAWKIT_COMMAND_ADDRESS
    commandDirectory = $env:SWAWKIT_COMMAND_DIR
    projectId = $env:SWAWKIT_PROJ_ID
    projectRoot = $env:SWAWKIT_PROJ_DIR
    actionRoot = $env:SWAWKIT_PROJ_ACTION_ROOT
    dataRoot = $env:SWAWKIT_PROJ_DATA_ROOT
    invocationDirectory = $env:SWAWKIT_INVOCATION_DIR
}

foreach ($Name in $Rows.Keys) {
    $Value = if ($null -eq $Rows[$Name]) { '' } else { [string]$Rows[$Name] }
    Write-Host ("{0,-20} {1}" -f $Name, $Value)
}
