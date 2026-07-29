[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$WindowsRoot = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::Windows
)
$SystemDirectory = [Environment]::SystemDirectory
if ([string]::IsNullOrWhiteSpace($WindowsRoot) -or
    -not [IO.Path]::IsPathRooted($WindowsRoot) -or
    [string]::IsNullOrWhiteSpace($SystemDirectory) -or
    -not [IO.Path]::IsPathRooted($SystemDirectory)) {
    throw 'The trusted Windows directories are unavailable or invalid.'
}
$WindowsRoot = [IO.Path]::GetFullPath($WindowsRoot)
$env:SystemRoot = $WindowsRoot
$env:windir = $WindowsRoot
$NativeSystemDirectory = if (
    [Environment]::Is64BitOperatingSystem -and
    -not [Environment]::Is64BitProcess
) {
    Join-Path $WindowsRoot 'Sysnative'
} else {
    $SystemDirectory
}
$Engine = Join-Path $NativeSystemDirectory 'WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $Engine -PathType Leaf)) {
    throw "Windows PowerShell 5.1 was not found: $Engine"
}

$Suites = @(
    'smoke.protocol.ps1',
    'smoke.runtime.security.ps1',
    'smoke.help.ps1',
    'smoke.key.ps1',
    'smoke.private.ps1',
    'smoke.public.references.ps1',
    'smoke.public.storage-atomicity.ps1',
    'smoke.public.policy-command.ps1',
    'smoke.global.capability.ps1',
    'smoke.global.shell.ps1',
    'smoke.global.ps1'
)

foreach ($Suite in $Suites) {
    $Path = Join-Path $PSScriptRoot $Suite
    Write-Host "[RUN] $Suite"
    & $Engine -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Path
    if ($LASTEXITCODE -ne 0) {
        throw "$Suite failed with exit code $LASTEXITCODE."
    }
    Write-Host "[OK]  $Suite"
}

Write-Host 'ssh access tests: PASS' -ForegroundColor Green
