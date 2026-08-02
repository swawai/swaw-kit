$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

. (Join-Path $PSScriptRoot '_core\entry-arguments.ps1')
. (Join-Path $PSScriptRoot '_core\engine.ps1')

try {
    [string[]]$CliArguments = @(
        Get-ProjEntryArguments -DirectArguments ([string[]]@($args))
    )
    [int]$ExitCode = Invoke-ProjMain `
        -KernelRoot $PSScriptRoot `
        -Arguments $CliArguments
    exit $ExitCode
} catch {
    if ($_.Exception.Data['SwawKit.Proj.SuppressErrorPrefix'] -eq $true) {
        [Console]::Error.WriteLine($_.Exception.Message)
    } else {
        [Console]::Error.WriteLine("[ERROR] $($_.Exception.Message)")
    }
    exit 1
}
