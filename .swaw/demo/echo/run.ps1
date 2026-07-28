$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

[Console]::WriteLine('SWAW Action demo.echo')
[Console]::WriteLine("commandAddress=$env:SWAWKIT_COMMAND_ADDRESS")
[Console]::WriteLine("projectId=$env:SWAWKIT_PROJ_ID")
[Console]::WriteLine("projectRoot=$env:SWAWKIT_PROJ_DIR")
[Console]::WriteLine("currentDirectory=$((Get-Location).ProviderPath)")
[Console]::WriteLine("invocationDirectory=$env:SWAWKIT_INVOCATION_DIR")
[Console]::WriteLine("argumentCount=$($args.Count)")

for ($Index = 0; $Index -lt $args.Count; $Index++) {
    $Display = [string]$args[$Index]
    $Display = $Display.Replace('\', '\\').Replace('"', '\"')
    $Display = $Display.Replace("`r", '\r').Replace("`n", '\n')
    $Display = $Display.Replace("`t", '\t')
    [Console]::WriteLine(('arg[{0}]="{1}"' -f $Index, $Display))
}
