$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

[string[]]$CommandArguments = @($args)
if ($CommandArguments.Count -eq 0) {
    throw '.dev/cmd requires non-empty command text.'
}
[string]$CommandText = [string]::Join(' ', $CommandArguments)
if ([string]::IsNullOrWhiteSpace($CommandText)) {
    throw '.dev/cmd requires non-empty command text.'
}

. (Join-Path $PSScriptRoot '..\..\..\_lib\process.ps1')
Import-ProjDevTargetEnvironment

$CmdPath = Resolve-ProjDevApplication `
    -Application 'cmd.exe' `
    -DisplayName 'Windows Command Prompt'
& $CmdPath /d /s /v:off /c $CommandText
exit ([int]$LASTEXITCODE)
