Set-StrictMode -Version 2.0

$SharedToolchainRoot = [IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\..\..\_toolchain')
)
. (Join-Path $SharedToolchainRoot '_lib\runtime.ps1')
