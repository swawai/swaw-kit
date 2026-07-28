$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

if (
    $args.Count -eq 1 -and
    @('.help', '.h', '-h', '--help') -ccontains [string]$args[0]
) {
    [Console]::WriteLine('Module-owned help: demo.native-help')
    [Console]::WriteLine('The help selector was forwarded to run.ps1.')
    [Console]::WriteLine("selector=$($args[0])")
    exit 0
}

[Console]::WriteLine('SWAW Action demo.native-help')
[Console]::WriteLine("argumentCount=$($args.Count)")
for ($Index = 0; $Index -lt $args.Count; $Index++) {
    [Console]::WriteLine(('arg[{0}]="{1}"' -f $Index, $args[$Index]))
}
