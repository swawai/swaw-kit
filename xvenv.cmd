@echo off
setlocal DisableDelayedExpansion

set "XVENV_SYSTEM_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "XVENV_KIT=%~dp0_lib\xvenv_kit\kit.ps1"

if not exist "%XVENV_SYSTEM_POWERSHELL%" (
    >&2 echo [ERROR] Windows PowerShell is required: "%XVENV_SYSTEM_POWERSHELL%"
    exit /b 1
)
if not exist "%XVENV_KIT%" (
    >&2 echo [ERROR] xvenv kit is missing: "%XVENV_KIT%"
    exit /b 1
)

"%XVENV_SYSTEM_POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%XVENV_KIT%" %*
exit /b %ERRORLEVEL%
