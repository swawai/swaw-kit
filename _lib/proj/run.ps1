$CommandName = if ([string]::IsNullOrWhiteSpace($env:SWAWKIT_PROJ_ENTRY_COMMAND)) {
    'proj'
} else {
    $env:SWAWKIT_PROJ_ENTRY_COMMAND
}

Write-Host 'Swaw Kit Proj command tree is ready.'
Write-Host 'The no-argument GUI host is not implemented yet.'
Write-Host "Try: $CommandName .info, $CommandName .help, $CommandName --help"
