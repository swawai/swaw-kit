@echo off
chcp 65001 >nul
setlocal

if not defined GIT_IDENTITY_ENTRY_COMMAND set "GIT_IDENTITY_ENTRY_COMMAND=git_identity"

if "%~1"=="-h" goto :ShowHelp
if /i "%~1"=="--help" goto :ShowHelp
if "%~1"=="/?" goto :ShowHelp

if /i "%~1"==".help" goto :ShowHelp
if /i "%~1"==".info" goto :WhoAmI
if /i "%~1"==".sync" goto :Sync
if /i "%~1"==".code" goto :LaunchCode
if /i "%~1"==".cursor" goto :LaunchCursor
if /i "%~1"==".cmd" goto :LaunchCmd
if /i "%~1"==".ps" goto :LaunchPowerShell
if /i "%~1"==".powershell" goto :LaunchPowerShell
if /i "%~1"==".pwsh" goto :LaunchPwsh

call :PrepareIdentity
if errorlevel 1 exit /b %ERRORLEVEL%

git %*
exit /b %ERRORLEVEL%

:ShowHelp
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0help.ps1" -CommandName "%GIT_IDENTITY_ENTRY_COMMAND%" -Language "%~2"
exit /b %ERRORLEVEL%

:WhoAmI
call :PrepareIdentity
if errorlevel 1 exit /b %ERRORLEVEL%

if /i "%~2"=="--verbose" (
    if not "%~3"=="" goto :WhoAmITooManyArguments
    goto :WhoAmIVerbose
)
if not "%~2"=="" goto :WhoAmIUnknownOption

call :ReadGitSeesIdentity
if defined GIT_IDENTITY_ENTRY_FILE echo Entry: %GIT_IDENTITY_ENTRY_FILE%
echo Name: %GIT_IDENTITY_NAME%
echo Email: %GIT_IDENTITY_EMAIL%
if defined GIT_IDENTITY_SSH_KEY echo SSH Key: %GIT_IDENTITY_SSH_KEY%

set "GIT_IDENTITY_NAME_MISMATCH="
set "GIT_IDENTITY_EMAIL_MISMATCH="
if not "%GIT_SEES_NAME%"=="%GIT_IDENTITY_NAME%" set "GIT_IDENTITY_NAME_MISMATCH=1"
if not "%GIT_SEES_EMAIL%"=="%GIT_IDENTITY_EMAIL%" set "GIT_IDENTITY_EMAIL_MISMATCH=1"

echo.
if not defined GIT_IDENTITY_NAME_MISMATCH if not defined GIT_IDENTITY_EMAIL_MISMATCH (
    set "GIT_IDENTITY_COLOR_TEXT=Git sees: OK"
    set "GIT_IDENTITY_COLOR=Green"
    call :EchoColor
    exit /b 0
)

set "GIT_IDENTITY_COLOR_TEXT=Git sees: MISMATCH"
set "GIT_IDENTITY_COLOR=Red"
call :EchoColor
if defined GIT_IDENTITY_NAME_MISMATCH (
    echo.
    echo Name:
    echo   Config: %GIT_IDENTITY_NAME%
    set "GIT_IDENTITY_COLOR_TEXT=  Git sees: %GIT_SEES_NAME%"
    set "GIT_IDENTITY_COLOR=Red"
    call :EchoColor
)
if defined GIT_IDENTITY_EMAIL_MISMATCH (
    echo.
    echo Email:
    echo   Config: %GIT_IDENTITY_EMAIL%
    set "GIT_IDENTITY_COLOR_TEXT=  Git sees: %GIT_SEES_EMAIL%"
    set "GIT_IDENTITY_COLOR=Red"
    call :EchoColor
)
exit /b 0

:WhoAmIVerbose
if defined GIT_IDENTITY_ENTRY_FILE echo Entry: %GIT_IDENTITY_ENTRY_FILE%
echo Name: %GIT_IDENTITY_NAME%
echo Email: %GIT_IDENTITY_EMAIL%
if defined GIT_IDENTITY_SSH_KEY echo SSH Key: %GIT_IDENTITY_SSH_KEY%
if defined GIT_IDENTITY_SIGNING_KEY echo Signing key: %GIT_IDENTITY_SIGNING_KEY%
echo.
echo Git sees:
git config --get user.name
git config --get user.email
exit /b %ERRORLEVEL%

:WhoAmIUnknownOption
echo [ERROR] Unrecognized .info option: %~2
echo Run "%GIT_IDENTITY_ENTRY_COMMAND% --help" for examples.
exit /b 1

:WhoAmITooManyArguments
echo [ERROR] Too many .info arguments.
echo Run "%GIT_IDENTITY_ENTRY_COMMAND% --help" for examples.
exit /b 1

:ReadGitSeesIdentity
set "GIT_SEES_NAME="
set "GIT_SEES_EMAIL="
for /f "delims=" %%A in ('git config --get user.name') do if not defined GIT_SEES_NAME set "GIT_SEES_NAME=%%A"
for /f "delims=" %%A in ('git config --get user.email') do if not defined GIT_SEES_EMAIL set "GIT_SEES_EMAIL=%%A"
exit /b 0

:EchoColor
PowerShell -NoProfile -ExecutionPolicy Bypass -Command "Write-Host $env:GIT_IDENTITY_COLOR_TEXT -ForegroundColor $env:GIT_IDENTITY_COLOR"
if errorlevel 1 echo %GIT_IDENTITY_COLOR_TEXT%
exit /b 0

:Sync
set "GIT_IDENTITY_SYNC_MODE=write"
if "%~2"=="" goto :SyncPrepare
if /i "%~2"=="--dry-run" set "GIT_IDENTITY_SYNC_MODE=dry-run" & goto :SyncPrepare
if /i "%~2"=="--clear" set "GIT_IDENTITY_SYNC_MODE=clear" & goto :RunSync
echo [ERROR] Unrecognized .sync option: %~2
echo Run "%GIT_IDENTITY_ENTRY_COMMAND% --help" for examples.
exit /b 1

:SyncPrepare
call :PrepareIdentity
if errorlevel 1 exit /b %ERRORLEVEL%

:RunSync
if not "%~3"=="" (
    echo [ERROR] Too many .sync arguments.
    echo Run "%GIT_IDENTITY_ENTRY_COMMAND% --help" for examples.
    exit /b 1
)
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync.ps1" -Mode "%GIT_IDENTITY_SYNC_MODE%" -EntryCommand "%GIT_IDENTITY_ENTRY_COMMAND%" -EntryFile "%GIT_IDENTITY_ENTRY_FILE%"
exit /b %ERRORLEVEL%

:LaunchCode
call :PrepareIdentity
if errorlevel 1 exit /b %ERRORLEVEL%
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch.ps1" -Tool "code" -DropFirst %*
exit /b %ERRORLEVEL%

:LaunchCursor
call :PrepareIdentity
if errorlevel 1 exit /b %ERRORLEVEL%
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch.ps1" -Tool "cursor" -DropFirst %*
exit /b %ERRORLEVEL%

:LaunchCmd
call :PrepareIdentity
if errorlevel 1 exit /b %ERRORLEVEL%
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch.ps1" -Tool "cmd" -DropFirst %*
exit /b %ERRORLEVEL%

:LaunchPowerShell
call :PrepareIdentity
if errorlevel 1 exit /b %ERRORLEVEL%
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch.ps1" -Tool "powershell" -DropFirst %*
exit /b %ERRORLEVEL%

:LaunchPwsh
call :PrepareIdentity
if errorlevel 1 exit /b %ERRORLEVEL%
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch.ps1" -Tool "pwsh" -DropFirst %*
exit /b %ERRORLEVEL%

:PrepareIdentity
if not defined GIT_IDENTITY_NAME goto :MissingIdentity
if not defined GIT_IDENTITY_EMAIL goto :MissingIdentity

set "GIT_AUTHOR_NAME=%GIT_IDENTITY_NAME%"
set "GIT_AUTHOR_EMAIL=%GIT_IDENTITY_EMAIL%"
set "GIT_COMMITTER_NAME=%GIT_IDENTITY_NAME%"
set "GIT_COMMITTER_EMAIL=%GIT_IDENTITY_EMAIL%"

set "GIT_CONFIG_COUNT=0"
call :AddGitConfig "user.name" "%GIT_IDENTITY_NAME%"
call :AddGitConfig "user.email" "%GIT_IDENTITY_EMAIL%"
if defined GIT_IDENTITY_SIGNING_KEY call :AddGitConfig "user.signingkey" "%GIT_IDENTITY_SIGNING_KEY%"
if defined GIT_IDENTITY_GPG_FORMAT call :AddGitConfig "gpg.format" "%GIT_IDENTITY_GPG_FORMAT%"

if defined GIT_SSH_COMMAND exit /b 0
if not defined GIT_IDENTITY_SSH_KEY exit /b 0
if not defined GIT_IDENTITY_SSH_OPTS set "GIT_IDENTITY_SSH_OPTS=-o IdentityAgent=none -o IdentitiesOnly=yes"
set "GIT_SSH_COMMAND=ssh %GIT_IDENTITY_SSH_OPTS% -i '%GIT_IDENTITY_SSH_KEY%'"
exit /b 0

:AddGitConfig
set "GIT_CONFIG_KEY_%GIT_CONFIG_COUNT%=%~1"
set "GIT_CONFIG_VALUE_%GIT_CONFIG_COUNT%=%~2"
set /a GIT_CONFIG_COUNT+=1
exit /b 0

:MissingIdentity
echo [ERROR] Git identity is not configured in "%GIT_IDENTITY_ENTRY_COMMAND%.cmd".
echo.
echo Set these lines near the top of the entry file:
echo   set "GIT_IDENTITY_NAME=Your Name"
echo   set "GIT_IDENTITY_EMAIL=you@example.com"
echo.
echo Run "%GIT_IDENTITY_ENTRY_COMMAND% --help" for examples.
exit /b 1
