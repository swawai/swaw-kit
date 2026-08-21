$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

. (Join-Path $PSScriptRoot '..\..\..\..\..\_lib\process.ps1')
Import-ProjDevTargetEnvironment

[string[]]$RustcArguments = @($args)
$RustcExecutable = Resolve-ProjDevApplication `
    -Application ([string]$env:RUSTC) `
    -DisplayName 'Rustc'
& $RustcExecutable @RustcArguments
exit ([int]$LASTEXITCODE)
