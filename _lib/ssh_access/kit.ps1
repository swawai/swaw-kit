$ErrorActionPreference = 'Stop'

try {
    . ([IO.Path]::Combine($PSScriptRoot, 'runtime\process-environment.ps1'))
    [void](Initialize-SshAccessTrustedProcessEnvironment)

    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    $OutputEncoding = [Text.UTF8Encoding]::new($false)
    [string[]]$CliArguments = @($args)

    . ([IO.Path]::Combine($PSScriptRoot, 'runtime\bootstrap.ps1'))

    [int]$ExitCode = Invoke-SshAccessMain -Arguments $CliArguments
    exit $ExitCode
} catch {
    [Console]::Error.WriteLine("[ERROR] $($_.Exception.Message)")
    exit 1
}
