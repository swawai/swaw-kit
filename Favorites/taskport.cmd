<# :
@echo off
setlocal
chcp 65001>nul
set "SWAW_KIT_SELF=%~f0"
set "SWAW_KIT_PROCESS_NAME=%~1"
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -Command "&{&([scriptblock]::Create([IO.File]::ReadAllText($env:SWAW_KIT_SELF)))}"
set "SWAW_KIT_EXIT=%ERRORLEVEL%"
set "SWAW_KIT_SELF="
set "SWAW_KIT_PROCESS_NAME="
pause
exit /b %SWAW_KIT_EXIT%
#>
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$name = $env:SWAW_KIT_PROCESS_NAME
if ([string]::IsNullOrWhiteSpace($name)) {
    Write-Host 'Please specify a process name.' -ForegroundColor Yellow
    exit 64
}

$procIds = Get-Process -Name $name -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty Id

if ($procIds) {
    Get-NetTCPConnection |
        Where-Object { $procIds -contains $_.OwningProcess } |
        Format-Table LocalAddress, LocalPort, RemoteAddress, RemotePort, State, OwningProcess -AutoSize
}
else {
    Write-Host "Find no: $name"
}

