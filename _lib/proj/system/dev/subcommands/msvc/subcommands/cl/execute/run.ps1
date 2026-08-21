$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

. (Join-Path $PSScriptRoot '..\..\..\..\..\_lib\process.ps1')
Import-ProjDevTargetEnvironment

[string[]]$CompilerArguments = @($args)
$CompilerExecutable = Resolve-ProjDevApplication `
    -Application 'cl.exe' `
    -DisplayName 'MSVC cl.exe'
& $CompilerExecutable @CompilerArguments
exit ([int]$LASTEXITCODE)
