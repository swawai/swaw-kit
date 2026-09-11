$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

[string[]]$Invocation = @($args)
if ($Invocation.Count -eq 0 -or [string]::IsNullOrWhiteSpace($Invocation[0])) {
    throw '.dev/exec requires an executable name followed by optional arguments.'
}

. (Join-Path $PSScriptRoot '..\..\..\_lib\process.ps1')
Import-ProjDevTargetEnvironment

$Executable = Resolve-ProjDevApplication `
    -Application $Invocation[0] `
    -DisplayName $Invocation[0]
[string[]]$Arguments = if ($Invocation.Count -gt 1) {
    $Invocation[1..($Invocation.Count - 1)]
} else {
    @()
}
& $Executable @Arguments
exit ([int]$LASTEXITCODE)
