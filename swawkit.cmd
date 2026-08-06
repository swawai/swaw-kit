@echo off & chcp 65001 >nul & setlocal DisableDelayedExpansion

:: Source-tree Bootstrap/recovery shim. It is never a project Entry itself:
:: once swawkit.exe is ready, all arguments and the exact exit code cross the
:: native Launcher boundary.
call :ClearInheritedContext
set "SWA_ENTRY_EXE=%~dp0swawkit.exe"
set "SWA_ENTRY_BOOTSTRAP=%~dp0_lib\proj\_bootstrap\entry.ps1"
set "SWA_SYSTEM_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if exist "%SWA_ENTRY_EXE%" goto RunEntry
if not exist "%SWA_ENTRY_BOOTSTRAP%" (
call :WriteError "Missing Proj Entry Bootstrap:"
echo   "%SWA_ENTRY_BOOTSTRAP%"
exit /b 1
)
if not exist "%SWA_SYSTEM_POWERSHELL%" (
call :WriteError "Windows PowerShell is required to prepare swawkit.exe:"
echo   "%SWA_SYSTEM_POWERSHELL%"
exit /b 1
)

set "SWA_BOOTSTRAP_PS_MODULE_PATH=%PSModulePath%"
set "PSModulePath="
"%SWA_SYSTEM_POWERSHELL%" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SWA_ENTRY_BOOTSTRAP%"
set "SWA_BOOTSTRAP_EXIT_CODE=%ERRORLEVEL%"
set "PSModulePath=%SWA_BOOTSTRAP_PS_MODULE_PATH%"
set "SWA_BOOTSTRAP_PS_MODULE_PATH="
if not "%SWA_BOOTSTRAP_EXIT_CODE%"=="0" exit /b %SWA_BOOTSTRAP_EXIT_CODE%
set "SWA_BOOTSTRAP_EXIT_CODE="
if not exist "%SWA_ENTRY_EXE%" (
call :WriteError "Proj Bootstrap completed without publishing swawkit.exe:"
echo   "%SWA_ENTRY_EXE%"
exit /b 1
)

:RunEntry
"%SWA_ENTRY_EXE%" %*
set "SWA_ENTRY_EXIT_CODE=%ERRORLEVEL%"
exit /b %SWA_ENTRY_EXIT_CODE%

:ClearInheritedContext
:: Entry identity and command-runtime facts must never leak into the native
:: Entry. Profile/toolchain declarations remain outside this launch envelope
:: and are resolved by the Rust Core.
for %%V in (
SWAWKIT_HOME
SWAWKIT_PROJ_PROTOCOL
SWAWKIT_PROJ_TARGET_PROJECT_ROOT
SWAWKIT_PROJ_ACTION_ROOT
SWAWKIT_PROJ_DATA_ROOT
SWAWKIT_PROJ_ENTRY_COMMAND
SWAWKIT_PROJ_ENTRY_FILE
SWAWKIT_PROJ_LAUNCH_MODE
SWAWKIT_PROJ_COMMAND_PROTOCOL
SWAWKIT_PROJ_COMMAND_PHASE
SWAWKIT_PROJ_COMMAND_ADDRESS
SWAWKIT_PROJ_COMMAND_DIR
SWAWKIT_PROJ_GUARD_SCOPE
SWAWKIT_PROJ_HELP_TARGET_ADDRESS
SWAWKIT_PROJ_INVOCATION_DIR
SWAWKIT_PROJ_INTERNAL_RUNTIME_WORKING_DIR
) do set "%%V="
for /F "tokens=1 delims==" %%V in ('set SWAWKIT_PROJ_ARGV_ 2^>nul') do set "%%V="
for /F "tokens=1 delims==" %%V in ('set SWAWKIT_PROJ_INTERNAL_PS_ 2^>nul') do set "%%V="
for /F "tokens=1 delims==" %%V in ('set SWAWKIT_PROJ_INTERNAL_CMD_ 2^>nul') do set "%%V="
exit /b 0

:WriteError
for /F "delims=" %%E in ('echo prompt $E^| cmd') do set "ESC=%%E"
echo %ESC%[31m[ERROR] %~1%ESC%[0m
exit /b 0
