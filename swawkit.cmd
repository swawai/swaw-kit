@echo off & chcp 65001 >nul & setlocal DisableDelayedExpansion & set "SWAWKIT_PROJ_PROTOCOL=1"

:: Required project resource
set "SWAWKIT_PROJ_DIR=%~dp0."
set "SWAWKIT_PROJ_ACTION_ROOT=%SWAWKIT_PROJ_DIR%\.swaw"


:: Optional project behavior
set "SWAWKIT_PROJ_DEFAULT_SHELL=pwsh"
set "SWAWKIT_PROJ_DEFAULT_IDE=code"

:: Optional portable development environment
set "SWAWKIT_PROJ_BUN_MODE=managed"
:: Version examples: latest (resolved once by .dev.setup) | 1.2.15
set "SWAWKIT_PROJ_BUN_VERSION=1.2.15"
:: Optional: pin the exact Bun release archive.
set "SWAWKIT_PROJ_BUN_SHA256="

set "SWAWKIT_PROJ_UV_MODE=managed"
set "SWAWKIT_PROJ_UV_VERSION=0.10.2"

set "SWAWKIT_PROJ_PYTHON_MODE=disabled"
:: set "SWAWKIT_PROJ_PYTHON_MODE=uv"
:: set "SWAWKIT_PROJ_PYTHON_VERSION=3.13"

set "SWAWKIT_PROJ_RUST_MODE=rustup"
:: Toolchain examples: stable | beta | nightly | nightly-2025-06-01 | 1.97 | 1.97.1 | 1.98.0-beta.1
:: This declaration is authoritative. After changing it, run: swawkit .dev.setup
set "SWAWKIT_PROJ_RUST_TOOLCHAIN=stable"
set "SWAWKIT_PROJ_RUST_PROFILE=minimal"
set "SWAWKIT_PROJ_RUST_HOST=x86_64-pc-windows-msvc"

set "SWAWKIT_PROJ_MSVC_MODE=managed"
set "SWAWKIT_PROJ_MSVC_CHANNEL=17"

set "SWAWKIT_PROJ_PWSH_MODE=managed"
:: Version examples: latest (resolved once by .dev.setup) | 7.6.4
set "SWAWKIT_PROJ_PWSH_VERSION=latest"
:: Optional: pin the exact PowerShell release archive.
set "SWAWKIT_PROJ_PWSH_SHA256="

set "SWAWKIT_PROJ_GO_MODE=disabled"
:: set "SWAWKIT_PROJ_GO_VERSION=1.22.4"

set "SWAWKIT_PROJ_GH_MODE=system"
set "SWAWKIT_PROJ_VSCODE_MODE=system"
set "SWAWKIT_PROJ_CURSOR_MODE=system"


:: Optional Git identity
set "SWAWKIT_PROJ_GIT_ID_NAME=SwawHQ"
set "SWAWKIT_PROJ_GIT_ID_EMAIL=swawhq@gmail.com"
set "SWAWKIT_PROJ_GIT_ID_ACCESS=ssh:ssh -o IdentitiesOnly=yes -i '%USERPROFILE%/.ssh/id_ed25519_swaw'"

:: Optional REPO context
set "SWAWKIT_PROJ_REPO_REMOTE=https://github.com/swawai/swaw-kit.git"


:: set "SWAWKIT_PROJ_HELP_LANG=zh-CN"




:::::::::::::::::::::::::::::::::::::::::::::::::::
:: Do not edit below.
:::::::::::::::::::::::::::::::::::::::::::::::::::
set "SWAWKIT_PROJ_RUNTIME=%~dp0_lib\proj\proj.ps1"
set "SWAWKIT_SYSTEM_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%SWAWKIT_PROJ_RUNTIME%" (
call :WriteError "Proj runtime not found:"
echo   "%SWAWKIT_PROJ_RUNTIME%"
echo.
call :WriteError "Missing _lib\proj\proj.ps1 next to this entry file."
exit /b 1
)

if not exist "%SWAWKIT_SYSTEM_POWERSHELL%" (
call :WriteError "Windows PowerShell is required:"
echo   "%SWAWKIT_SYSTEM_POWERSHELL%"
exit /b 1
)

set "SWAWKIT_PROJ_ENTRY_FILE=%~f0"

:: Relay argv as data. Expanding %%* on another command line would make CMD
:: parse metacharacters again and would also lose explicit empty arguments.
set "SWAWKIT_PROJ_ARGV_PROTOCOL=1"
set "SWAWKIT_PROJ_ARGV_COUNT=0"

:CaptureProjArgument
set "SWAWKIT_PROJ_ARG_VALUE=%~1"
if defined SWAWKIT_PROJ_ARG_VALUE goto StoreProjArgument
if x%1==x goto RunProj

:StoreProjArgument
set /a SWAWKIT_PROJ_ARGV_COUNT+=1 >nul
set "SWAWKIT_PROJ_ARGV_%SWAWKIT_PROJ_ARGV_COUNT%=%~1"
shift /1
goto CaptureProjArgument

:RunProj
set "SWAWKIT_PROJ_ARG_VALUE="
"%SWAWKIT_SYSTEM_POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SWAWKIT_PROJ_RUNTIME%"
exit /b %ERRORLEVEL%

:WriteError
for /F "delims=" %%E in ('echo prompt $E^| cmd') do set "ESC=%%E"
echo %ESC%[31m[ERROR] %~1%ESC%[0m
exit /b 0
