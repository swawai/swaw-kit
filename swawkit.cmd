@echo off & chcp 65001 >nul & setlocal DisableDelayedExpansion

:: Transitional source-tree Entry. Public command routing belongs to the Rust
:: Core; PowerShell is started only when that shared Core must be bootstrapped.
call :ClearInheritedContext
set "SWAWKIT_PROJ_CORE=%~dp0_lib\proj\_bin\swawkit-proj.exe"
set "SWAWKIT_PROJ_BOOTSTRAP=%~dp0_lib\proj\_bootstrap\run.ps1"
set "SWAWKIT_PROJ_INTERNAL_SYSTEM_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if exist "%SWAWKIT_PROJ_CORE%" goto CaptureArguments
if not exist "%SWAWKIT_PROJ_BOOTSTRAP%" (
call :WriteError "Missing Proj Bootstrap:"
echo   "%SWAWKIT_PROJ_BOOTSTRAP%"
exit /b 1
)
if not exist "%SWAWKIT_PROJ_INTERNAL_SYSTEM_POWERSHELL%" (
call :WriteError "Windows PowerShell is required to bootstrap Proj:"
echo   "%SWAWKIT_PROJ_INTERNAL_SYSTEM_POWERSHELL%"
exit /b 1
)

set "SWA_BOOTSTRAP_PS_MODULE_PATH=%PSModulePath%"
set "PSModulePath="
"%SWAWKIT_PROJ_INTERNAL_SYSTEM_POWERSHELL%" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SWAWKIT_PROJ_BOOTSTRAP%"
set "SWA_BOOTSTRAP_EXIT_CODE=%ERRORLEVEL%"
set "PSModulePath=%SWA_BOOTSTRAP_PS_MODULE_PATH%"
set "SWA_BOOTSTRAP_PS_MODULE_PATH="
if not "%SWA_BOOTSTRAP_EXIT_CODE%"=="0" exit /b %SWA_BOOTSTRAP_EXIT_CODE%
set "SWA_BOOTSTRAP_EXIT_CODE="
if not exist "%SWAWKIT_PROJ_CORE%" (
call :WriteError "Proj Bootstrap completed without publishing the shared Core:"
echo   "%SWAWKIT_PROJ_CORE%"
exit /b 1
)

:CaptureArguments
set "SWAWKIT_PROJ_ENTRY_FILE=%~f0"
set "SWAWKIT_PROJ_ARGV_PROTOCOL=1"
set "SWAWKIT_PROJ_ARGV_COUNT=0"

:CaptureArgument
set "SWAWKIT_PROJ_ARG_VALUE=%~1"
if defined SWAWKIT_PROJ_ARG_VALUE goto StoreArgument
if x%1==x goto RunCore

:StoreArgument
set /a SWAWKIT_PROJ_ARGV_COUNT+=1 >nul
set "SWAWKIT_PROJ_ARGV_%SWAWKIT_PROJ_ARGV_COUNT%=%~1"
shift /1
goto CaptureArgument

:RunCore
set "SWAWKIT_PROJ_ARG_VALUE="
if not "%SWAWKIT_PROJ_ARGV_COUNT%"=="0" goto RunCli
:: The Core owns background process creation. ..web self-spawns the hidden Host
:: and returns, so this transitional CMD never needs START or a resident shell.
set "SWAWKIT_PROJ_ARGV_COUNT=1"
set "SWAWKIT_PROJ_ARGV_1=..web"

:RunCli
set "SWAWKIT_PROJ_LAUNCH_MODE=cli"
"%SWAWKIT_PROJ_CORE%"
exit /b %ERRORLEVEL%

:ClearInheritedContext
:: Entry identity and command-runtime facts must never leak across copied Entry
:: files. Profile/toolchain declarations are intentionally outside this launch
:: envelope and are resolved by the Rust Core.
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
