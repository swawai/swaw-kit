$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

if ($args.Count -ne 0) {
    throw 'proj.build.launcher does not accept dynamic arguments.'
}

$KernelRoot = [IO.Path]::GetFullPath(
    (Join-Path ([string]$env:SWAWKIT_HOME) '_lib\proj')
)
. (Join-Path $KernelRoot '_core\engine.ps1')
. (Join-Path $KernelRoot '.dev\setup\_modules\msvc\runtime.ps1')
[void](Import-ProjDevMsvcCommandEnvironment)
. (Join-Path $PSScriptRoot '_lib\policy.ps1')

$ProjectRoot = [string]$env:SWAWKIT_PROJ_TARGET_PROJECT_ROOT
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
