@echo off
setlocal DisableDelayedExpansion
set "WIN_RUN_EDITOR_BOOTSTRAP="
set "WIN_RUN_EDITOR_TOOL="
set "WIN_RUN_EDITOR_FORBIDDEN_ENV=%~2"
if /i "%~1"==".code" set "WIN_RUN_EDITOR_TOOL=code"
if /i "%~1"==".cursor" set "WIN_RUN_EDITOR_TOOL=cursor"
if not defined WIN_RUN_EDITOR_TOOL goto :NoBootstrap

if not defined WIN_RUN_EDITOR_FORBIDDEN_ENV goto :LaunchWithoutEnvironmentGuard
call PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0entry-bootstrap.ps1" -Tool "%WIN_RUN_EDITOR_TOOL%" -ForbiddenEnvironmentVariable "%WIN_RUN_EDITOR_FORBIDDEN_ENV%"
goto :CaptureResult

:LaunchWithoutEnvironmentGuard
call PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0entry-bootstrap.ps1" -Tool "%WIN_RUN_EDITOR_TOOL%"

:CaptureResult
set "WIN_RUN_EDITOR_RESULT=%ERRORLEVEL%"
if "%WIN_RUN_EDITOR_RESULT%"=="10" goto :Created
if "%WIN_RUN_EDITOR_RESULT%"=="0" goto :NoBootstrap
goto :Failed

:Created
endlocal & set "WIN_RUN_EDITOR_BOOTSTRAP=%WIN_RUN_EDITOR_TOOL%" & exit /b 0

:NoBootstrap
endlocal & set "WIN_RUN_EDITOR_BOOTSTRAP=" & exit /b 0

:Failed
endlocal & set "WIN_RUN_EDITOR_BOOTSTRAP=" & exit /b %WIN_RUN_EDITOR_RESULT%
