$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

. (Join-Path $PSScriptRoot '..\..\..\_lib\process.ps1')
Import-ProjDevTargetEnvironment

$BunExecutable = Resolve-ProjDevApplication `
    -Application 'bun.exe' `
    -DisplayName 'Bun'
[string[]]$BunArguments = @($args)
& $BunExecutable @BunArguments
exit ([int]$LASTEXITCODE)
