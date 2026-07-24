$ErrorActionPreference = 'Stop'
[string[]]$CliArguments = @($args)
$SystemPowerShell = Join-Path `
    $env:SystemRoot `
    'System32\WindowsPowerShell\v1.0\powershell.exe'
$Kit = Join-Path $PSScriptRoot '_lib\xvenv_kit\kit.ps1'
$Protocol = Join-Path $PSScriptRoot '_lib\xvenv_kit\shared\protocol.ps1'

try {
    foreach ($RequiredPath in @($SystemPowerShell, $Kit, $Protocol)) {
        if (-not [IO.File]::Exists($RequiredPath)) {
            throw "xvenv runtime is missing: $RequiredPath"
        }
    }

    . $Protocol
    $Payload = ConvertTo-XvenvArgumentPayload -Arguments $CliArguments
    if ($Payload.Length -gt 30000) {
        throw 'xvenv arguments exceed the Windows command-line limit.'
    }

    $PreviousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $SystemPowerShell `
            -NoLogo `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $Kit `
            --xvenv-argument-payload $Payload
        $ChildExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $PreviousPreference
    }
    exit $ChildExitCode
} catch {
    [Console]::Error.WriteLine("[ERROR] $($_.Exception.Message)")
    exit 1
}
