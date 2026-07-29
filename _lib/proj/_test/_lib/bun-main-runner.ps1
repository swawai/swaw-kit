param(
    [Parameter(Mandatory = $true)][string]$KernelRoot,
    [Parameter(Mandatory = $true)][string]$WorkingDirectory,
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$ArgumentPayload
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

Set-Location -LiteralPath $WorkingDirectory
. (Join-Path $KernelRoot '_core\engine.ps1')
[string[]]$DecodedArguments = @(
    ConvertFrom-ProjArgumentPayload -Payload $ArgumentPayload
)
exit ([int](Invoke-ProjMain `
    -KernelRoot $KernelRoot `
    -Arguments $DecodedArguments))
