$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

if ($args.Count -ne 0) {
    throw 'proj.build.launcher does not accept dynamic arguments.'
}

function Resolve-ManagedMsvcExecutable {
    param([Parameter(Mandatory = $true)][string]$Name)

    if ([string]$env:SWAWKIT_DEV_ENV_SCHEMA -cne
            'swawkit.proj-dev.environment.v0' -or
        [string]$env:SWAWKIT_DEV_MSVC_MODE -cne 'managed' -or
        [string]::IsNullOrWhiteSpace(
            [string]$env:SWAWKIT_DEV_MSVC_HOME
        ) -or
        [string]::IsNullOrWhiteSpace(
            [string]$env:SWAWKIT_DEV_MSVC_SIGNATURE
        )) {
        throw (
            'proj.build.launcher requires the project-managed MSVC ' +
            "environment. Enable it and run " +
            "'$($env:SWAWKIT_PROJ_ENTRY_COMMAND) .dev.setup'."
        )
    }

    $Command = Get-Command $Name `
        -CommandType Application `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $Command) {
        throw (
            "Managed MSVC does not expose $Name. Run " +
            "'$($env:SWAWKIT_PROJ_ENTRY_COMMAND) .dev.setup'."
        )
    }

    $ManagedRoot = [IO.Path]::GetFullPath(
        [string]$env:SWAWKIT_DEV_MSVC_HOME
    ).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $ExecutablePath = [IO.Path]::GetFullPath([string]$Command.Source)
    if (-not $ExecutablePath.StartsWith(
        $ManagedRoot,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw (
            "$Name resolved outside the project-managed MSVC environment: " +
            "$ExecutablePath"
        )
    }
    return $ExecutablePath
}

$ProjectRoot = [string]$env:SWAWKIT_PROJ_DIR
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    throw 'The project runtime context is incomplete.'
}

$BuildScript = Join-Path $ProjectRoot (
    '_lib\proj\_launcher\build.ps1'
)
if (-not [IO.File]::Exists($BuildScript)) {
    throw "Launcher build script not found: $BuildScript"
}

$CompilerPath = Resolve-ManagedMsvcExecutable -Name 'cl.exe'
$LinkerPath = Resolve-ManagedMsvcExecutable -Name 'link.exe'
& $BuildScript -CompilerPath $CompilerPath -LinkerPath $LinkerPath
