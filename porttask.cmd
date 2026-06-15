<# :
@echo off
setlocal
chcp 65001>nul
set "WIN_RUN_TOOLBOX_SELF=%~f0"
set "WIN_RUN_TOOLBOX_PATTERN=%~1"
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -Command "&{&([scriptblock]::Create([IO.File]::ReadAllText($env:WIN_RUN_TOOLBOX_SELF)))}"
set "WIN_RUN_TOOLBOX_EXIT=%ERRORLEVEL%"
set "WIN_RUN_TOOLBOX_SELF="
set "WIN_RUN_TOOLBOX_PATTERN="
pause
exit /b %WIN_RUN_TOOLBOX_EXIT%
#>
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$Pattern = $env:WIN_RUN_TOOLBOX_PATTERN
if ([string]::IsNullOrWhiteSpace($Pattern)) {
    Write-Host "Please specify a local port pattern, e.g. '80*' or '443'." -ForegroundColor Yellow
    exit 64
}

$tcpConns = Get-NetTCPConnection -ErrorAction SilentlyContinue
$udpConns = Get-NetUDPEndpoint -ErrorAction SilentlyContinue

$matches = ($tcpConns + $udpConns) |
    Where-Object { $_.LocalPort.ToString() -like $Pattern }

if ($matches) {
    $unique = $matches |
        Select-Object LocalPort, OwningProcess -Unique |
        Sort-Object LocalPort

    $rows = $unique | ForEach-Object {
        $processId = $_.OwningProcess
        $portNumber = $_.LocalPort
        try {
            $proc = Get-Process -Id $processId -ErrorAction Stop
            $name = $proc.ProcessName
        }
        catch {
            $name = '<Unknown>'
        }

        [PSCustomObject]@{
            Port        = $portNumber
            PID         = $processId
            ProcessName = $name
        }
    }

    $rows | Format-Table -AutoSize
}
else {
    Write-Host "No listeners found for ports matching pattern '$Pattern'." -ForegroundColor Yellow
}
