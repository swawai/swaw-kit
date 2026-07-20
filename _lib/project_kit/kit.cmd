@echo off
chcp 65001 >nul
setlocal

if not defined PROJECT_ENTRY_COMMAND set "PROJECT_ENTRY_COMMAND=project"

if /i "%~1"=="--help" goto :ShowHelp
if /i "%~1"=="-h" goto :ShowHelp
if "%~1"=="/?" goto :ShowHelp
if /i "%~1"==".help" goto :ShowHelp
goto :NotImplemented

:ShowHelp
where PowerShell.exe >nul 2>nul
if errorlevel 1 (
    echo [ERROR] PowerShell.exe is required to render Project Kit help.
    exit /b 1
)

if not exist "%~dp0help.ps1" (
    echo [ERROR] Help renderer not found: "%~dp0help.ps1"
    exit /b 1
)

PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0help.ps1" -CommandName "%PROJECT_ENTRY_COMMAND%" -Language "%~2"
exit /b %ERRORLEVEL%

:NotImplemented
echo [ERROR] Project Kit 命令当前尚未实现: %*
echo 请运行 "%PROJECT_ENTRY_COMMAND% --help" 查看当前功能契约。
exit /b 1
