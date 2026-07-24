$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
[string[]]$RawCliArguments = @($args)

. (Join-Path $PSScriptRoot 'bootstrap.ps1')

try {
    [string[]]$CliArguments = $RawCliArguments
    if ($RawCliArguments.Count -gt 0 -and
        $RawCliArguments[0] -ceq '--xvenv-argument-payload') {
        if ($RawCliArguments.Count -ne 2) {
            throw 'The internal xvenv argument payload invocation is invalid.'
        }
        $CliArguments = [string[]]@(
            ConvertFrom-XvenvArgumentPayload $RawCliArguments[1]
        )
    }
    [int]$ExitCode = Invoke-XvenvMain -Arguments $CliArguments
    exit $ExitCode
} catch {
    [Console]::Error.WriteLine("[ERROR] $($_.Exception.Message)")
    exit 1
}
