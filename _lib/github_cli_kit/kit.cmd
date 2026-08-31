@echo off
chcp 65001 >nul <nul
setlocal DisableDelayedExpansion

if not "%GH_ID_KIT_PROTOCOL%"=="2" goto :UnsupportedProtocol
if not defined GH_ID_ENTRY_COMMAND set "GH_ID_ENTRY_COMMAND=gh_identity"

if "%~1"=="-h" goto :ShowHelp
if /i "%~1"=="--help" goto :ShowHelp
if "%~1"=="/?" goto :ShowHelp
if /i "%~1"==".help" goto :ShowHelp

call :ValidateConfiguration
if errorlevel 1 exit /b %ERRORLEVEL%

if "%~1"=="" goto :LaunchDefaultTerminal
if /i "%~1"==".info" goto :ShowInfo
if /i "%~1"==".doctor" goto :RunDoctor
if /i "%~1"==".setup" goto :SetupRuntime
if /i "%~1"==".cmd" goto :LaunchCmd
if /i "%~1"==".powershell" goto :LaunchPowerShell
if /i "%~1"==".pwsh" goto :LaunchPwsh
if /i "%~1"==".gitbash" goto :LaunchGitBash

set "GH_ID_FIRST_ARGUMENT=%~1"
if "%GH_ID_FIRST_ARGUMENT:~0,1%"=="." goto :UnknownKitCommand
if /i "%~1"=="auth" if /i "%~2"=="login" goto :RunBoundAuthLogin
goto :RunGh

:ShowHelp
if not "%~3"=="" goto :InvalidHelpCommand
if "%~2"=="" goto :RenderHelp
if /i "%~2"=="zh" goto :RenderHelp
if /i "%~2"=="zh-CN" goto :RenderHelp
if /i "%~2"=="en" goto :RenderHelp
goto :InvalidHelpCommand

:RenderHelp
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0help.ps1" -CommandName "%GH_ID_ENTRY_COMMAND%" -Language "%~2"
exit /b %ERRORLEVEL%

:InvalidHelpCommand
echo [ERROR] Use "%GH_ID_ENTRY_COMMAND% .help", ".help zh", or ".help en".
exit /b 1

:ShowInfo
if not "%~2"=="" goto :NoArgumentsExpected
call :ResolveExistingRuntime
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0info.ps1"
exit /b %ERRORLEVEL%

:RunDoctor
if not "%~2"=="" goto :NoArgumentsExpected
call :ResolveExistingRuntime
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0doctor.ps1"
exit /b %ERRORLEVEL%

:SetupRuntime
if not "%~2"=="" goto :NoArgumentsExpected
call :ResolveExistingRuntime
if /i "%GH_ID_RUNTIME_SOURCE%"=="system" goto :SystemRuntimeAvailable
call :EnsurePortableRuntime
if errorlevel 1 exit /b %ERRORLEVEL%
call :PrintGhVersion
exit /b %ERRORLEVEL%

:SystemRuntimeAvailable
echo [OK] System GitHub CLI is available:
echo   "%GH_ID_GH_EXE%"
call :PrintGhVersion
exit /b %ERRORLEVEL%

:LaunchDefaultTerminal
if not defined GH_ID_DEFAULT_TERMINAL goto :LaunchCmd
if /i "%GH_ID_DEFAULT_TERMINAL%"=="cmd" goto :LaunchCmd
if /i "%GH_ID_DEFAULT_TERMINAL%"=="powershell" goto :LaunchPowerShell
if /i "%GH_ID_DEFAULT_TERMINAL%"=="pwsh" goto :LaunchPwsh
if /i "%GH_ID_DEFAULT_TERMINAL%"=="gitbash" goto :LaunchGitBash
echo [ERROR] Invalid GH_ID_DEFAULT_TERMINAL: %GH_ID_DEFAULT_TERMINAL%
echo Use cmd, powershell, pwsh, or gitbash.
exit /b 1

:LaunchCmd
set "GH_ID_LAUNCH_TOOL=cmd"
goto :LaunchTerminal

:LaunchPowerShell
set "GH_ID_LAUNCH_TOOL=powershell"
goto :LaunchTerminal

:LaunchPwsh
set "GH_ID_LAUNCH_TOOL=pwsh"
goto :LaunchTerminal

:LaunchGitBash
set "GH_ID_LAUNCH_TOOL=gitbash"

:LaunchTerminal
call :RequireRuntime
if errorlevel 1 exit /b %ERRORLEVEL%
call :SelectExpectedAccount
if errorlevel 1 exit /b %ERRORLEVEL%
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch.ps1" -Tool "%GH_ID_LAUNCH_TOOL%" -DropFirst %*
exit /b %ERRORLEVEL%

:RunBoundAuthLogin
call :RequireRuntime
if errorlevel 1 exit /b %ERRORLEVEL%
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0auth-login.ps1" %*
exit /b %ERRORLEVEL%

:RunGh
call :RequireRuntime
if errorlevel 1 exit /b %ERRORLEVEL%
call :ApplyAutomationEnvironment
call :SelectExpectedAccount
if errorlevel 1 exit /b %ERRORLEVEL%
if /i "%GH_ID_GH_EXTENSION%"==".cmd" goto :RunGhBatch
if /i "%GH_ID_GH_EXTENSION%"==".bat" goto :RunGhBatch
"%GH_ID_GH_EXE%" %*
goto :AfterGh

:RunGhBatch
call "%GH_ID_GH_EXE%" %*

:AfterGh
set "GH_ID_GH_RESULT=%ERRORLEVEL%"
if not "%GH_ID_GH_RESULT%"=="0" exit /b %GH_ID_GH_RESULT%
if /i "%~1"=="auth" if /i "%~2"=="switch" goto :AssertActiveAccount
exit /b 0

:AssertActiveAccount
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0assert-account.ps1"
exit /b %ERRORLEVEL%

:SelectExpectedAccount
if /i "%GH_ID_FIRST_ARGUMENT%"=="help" exit /b 0
if /i "%GH_ID_FIRST_ARGUMENT%"=="version" exit /b 0
if /i "%GH_ID_FIRST_ARGUMENT%"=="--version" exit /b 0
if /i "%GH_ID_FIRST_ARGUMENT%"=="completion" exit /b 0
if /i "%GH_ID_FIRST_ARGUMENT%"=="config" exit /b 0
if /i "%GH_ID_FIRST_ARGUMENT%"=="alias" exit /b 0
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0select-account.ps1"
exit /b %ERRORLEVEL%

:ApplyAutomationEnvironment
set "GH_PROMPT_DISABLED=1"
set "GH_PAGER=cat"
set "GH_SPINNER_DISABLED=1"
set "GH_NO_UPDATE_NOTIFIER=1"
set "GH_NO_EXTENSION_UPDATE_NOTIFIER=1"
set "NO_COLOR=1"
set "GH_FORCE_TTY="
set "CLICOLOR_FORCE="
set "GIT_TERMINAL_PROMPT=0"
set "GCM_INTERACTIVE=false"
exit /b 0

:ValidateConfiguration
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0validate-config.ps1"
exit /b %ERRORLEVEL%

:RequireRuntime
call :ResolveExistingRuntime
if /i "%GH_ID_RUNTIME_SOURCE%"=="system" goto :RuntimeReady
call :EnsurePortableRuntime
if errorlevel 1 exit /b %ERRORLEVEL%

:RuntimeReady
for %%I in ("%GH_ID_GH_EXE%") do set "GH_ID_GH_EXTENSION=%%~xI"
for %%I in ("%GH_ID_GH_EXE%") do set "PATH=%%~dpI;%PATH%"
if /i "%GH_ID_RUNTIME_SOURCE%"=="portable" set "GH_NO_UPDATE_NOTIFIER=1"
exit /b 0

:ResolveExistingRuntime
set "GH_ID_GH_EXE="
set "GH_ID_RUNTIME_SOURCE=missing"
for %%I in ("%~dp0..\..\data\github-cli\runtime\current\bin\gh.exe") do set "GH_ID_PORTABLE_EXE=%%~fI"
for /f "delims=" %%I in ('where.exe gh 2^>nul') do if not defined GH_ID_GH_EXE set "GH_ID_GH_EXE=%%~fI"
if not defined GH_ID_GH_EXE goto :CheckPortableRuntime
if /i "%GH_ID_GH_EXE%"=="%GH_ID_PORTABLE_EXE%" goto :ResolvedPortableRuntime
set "GH_ID_RUNTIME_SOURCE=system"
exit /b 0

:ResolvedPortableRuntime
set "GH_ID_RUNTIME_SOURCE=portable"
exit /b 0

:CheckPortableRuntime
if not exist "%GH_ID_PORTABLE_EXE%" exit /b 0
set "GH_ID_GH_EXE=%GH_ID_PORTABLE_EXE%"
set "GH_ID_RUNTIME_SOURCE=portable"
exit /b 0

:PrintGhVersion
for %%I in ("%GH_ID_GH_EXE%") do set "GH_ID_GH_EXTENSION=%%~xI"
if /i "%GH_ID_GH_EXTENSION%"==".cmd" goto :PrintGhBatchVersion
if /i "%GH_ID_GH_EXTENSION%"==".bat" goto :PrintGhBatchVersion
"%GH_ID_GH_EXE%" --version
exit /b %ERRORLEVEL%

:PrintGhBatchVersion
call "%GH_ID_GH_EXE%" --version
exit /b %ERRORLEVEL%

:EnsurePortableRuntime
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0runtime.ps1" -Mode Ensure
if errorlevel 1 exit /b %ERRORLEVEL%
set "GH_ID_GH_EXE=%GH_ID_PORTABLE_EXE%"
set "GH_ID_RUNTIME_SOURCE=portable"
exit /b 0

:UnknownKitCommand
echo [ERROR] Unknown GitHub CLI kit command: %~1
echo Custom commands start with a dot. Run "%GH_ID_ENTRY_COMMAND% .help".
exit /b 1

:NoArgumentsExpected
echo [ERROR] %~1 does not accept arguments.
exit /b 1

:UnsupportedProtocol
echo [ERROR] This GitHub CLI entry is incompatible with the installed kit.
echo Expected GH_ID_KIT_PROTOCOL=2.
exit /b 1
