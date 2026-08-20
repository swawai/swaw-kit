$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

[string[]]$Invocation = @($args)
if ($Invocation.Count -lt 2) {
    throw '.dev/pwsh requires -File <path.ps1> or -Command <script>.'
}

$Mode = [string]$Invocation[0]
$Target = $null
$CommandText = $null
[string[]]$TargetArguments = @()
if ($Mode -ieq '-File') {
    $DeclaredPath = [string]$Invocation[1]
    if ([string]::IsNullOrWhiteSpace($DeclaredPath)) {
        throw '.dev/pwsh -File requires a non-empty script path.'
    }
    $Target = if ([IO.Path]::IsPathRooted($DeclaredPath)) {
        [IO.Path]::GetFullPath($DeclaredPath)
    } else {
        [IO.Path]::GetFullPath($DeclaredPath)
    }
    $TargetItem = Get-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
    if ([IO.Path]::GetExtension($Target) -ine '.ps1') {
        throw ".dev/pwsh -File requires a .ps1 script: $Target"
    }
    if ($null -eq $TargetItem -or $TargetItem.PSIsContainer -or
        ($TargetItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "PowerShell script does not exist or is unsafe: $Target"
    }
    if ($Invocation.Count -gt 2) {
        $TargetArguments = $Invocation[2..($Invocation.Count - 1)]
    }
} elseif ($Mode -ieq '-Command') {
    $CommandText = [string]::Join(
        ' ',
        [string[]]$Invocation[1..($Invocation.Count - 1)]
    )
    if ([string]::IsNullOrWhiteSpace($CommandText)) {
        throw '.dev/pwsh -Command requires non-empty script text.'
    }
} else {
    throw ".dev/pwsh accepts only -File or -Command; received: $Mode"
}

. (Join-Path $PSScriptRoot '..\_lib\process.ps1')
Import-ProjDevTargetEnvironment

$PwshExecutable = Resolve-ProjDevApplication `
    -Application 'pwsh.exe' `
    -DisplayName 'PowerShell 7'
$PwshArguments = @(
    '-NoLogo',
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass'
)
if ($Mode -ieq '-File') {
    & $PwshExecutable @PwshArguments -File $Target @TargetArguments
} else {
    & $PwshExecutable @PwshArguments -Command $CommandText
}
exit ([int]$LASTEXITCODE)
