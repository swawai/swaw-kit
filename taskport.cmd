<# :
@echo off
setlocal
chcp 65001>nul
set "WIN_RUN_TOOLBOX_SELF=%~f0"
set "WIN_RUN_TOOLBOX_PROCESS_NAME=%~1"
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -Command "&{&([scriptblock]::Create([IO.File]::ReadAllText($env:WIN_RUN_TOOLBOX_SELF)))}"
set "WIN_RUN_TOOLBOX_EXIT=%ERRORLEVEL%"
set "WIN_RUN_TOOLBOX_SELF="
set "WIN_RUN_TOOLBOX_PROCESS_NAME="
pause
exit /b %WIN_RUN_TOOLBOX_EXIT%
#>
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$name = $env:WIN_RUN_TOOLBOX_PROCESS_NAME
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

