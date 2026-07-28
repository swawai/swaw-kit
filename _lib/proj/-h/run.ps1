# This is a real command module, but its behavior is an address alias.
# Re-enter Core so .help keeps one canonical resolver and runtime path.
& (Join-Path $PSScriptRoot '..\proj.ps1') '.help' @args
