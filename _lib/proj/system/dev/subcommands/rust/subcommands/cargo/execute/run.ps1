$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

. (Join-Path $PSScriptRoot '..\..\..\..\..\_lib\process.ps1')
Import-ProjDevTargetEnvironment

[string[]]$CargoArguments = @($args)
$CargoExecutable = Resolve-ProjDevApplication `
    -Application 'cargo.exe' `
    -DisplayName 'Cargo'
& $CargoExecutable @CargoArguments
exit ([int]$LASTEXITCODE)
