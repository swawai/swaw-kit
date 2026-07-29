@echo off
chcp 65001 >nul <nul
setlocal DisableDelayedExpansion

for %%I in ("%__APPDIR__%..") do set "SSH_ACCESS_WINDOWS_ROOT=%%~fI"
set "SystemRoot=%SSH_ACCESS_WINDOWS_ROOT%"
set "windir=%SSH_ACCESS_WINDOWS_ROOT%"

set "SSH_ACCESS_POWERSHELL=%__APPDIR__%WindowsPowerShell\v1.0\powershell.exe"
if exist "%__APPDIR__%..\Sysnative\WindowsPowerShell\v1.0\powershell.exe" (
    set "SSH_ACCESS_POWERSHELL=%__APPDIR__%..\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
)
if not exist "%SSH_ACCESS_POWERSHELL%" (
    echo [ERROR] Windows PowerShell was not found:
    echo   "%SSH_ACCESS_POWERSHELL%"
    exit /b 1
)

"%SSH_ACCESS_POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0kit.ps1" %*
exit /b %ERRORLEVEL%
