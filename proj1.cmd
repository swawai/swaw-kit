@echo off & chcp 65001 >nul & setlocal & set "PROJECT_KIT_PROTOCOL=1"

:: Required
set "PROJECT_DIR=D:\2026.3\ex_\xvenv"

:: Optional project behavior
set "PROJECT_DEFAULT_SHELL=pwsh"
set "PROJECT_DEFAULT_IDE=code"



:: Optional Git identity
set "GIT_ID_NAME=user1"
set "GIT_ID_EMAIL=user1@example.com"
set "GIT_SSH_COMMAND=ssh -i '%USERPROFILE%/.ssh/id_ed25519' -o IdentitiesOnly=yes"
set "GIT_SSH_VARIANT=ssh"
:: Optional GitHub context
:: set "GH_REPO=owner/repo"



:: set "PROJECT_DATA_ROOT=%~dp0data"
:: set "PROJECT_HELP_LANG=zh-CN"



:::::::::::::::::::::::::::::::::::::::::::::::::::
:: Do not edit below.
:::::::::::::::::::::::::::::::::::::::::::::::::::
set "PROJECT_KIT=%~dp0_lib\project_kit\kit.cmd"

if exist "%PROJECT_KIT%" goto :ProjectKitFound
call :WriteError "Project kit not found:"
echo   "%PROJECT_KIT%"
echo.
call :WriteError "Missing _lib\project_kit\kit.cmd next to this entry file."
exit /b 1

:ProjectKitFound
set "PROJECT_ENTRY_COMMAND=%~n0"
set "PROJECT_ENTRY_FILE=%~f0"
if "%~1"=="/?" goto :ProjectKitSlashHelp
call "%PROJECT_KIT%" %*
exit /b %ERRORLEVEL%

:ProjectKitSlashHelp
call "%PROJECT_KIT%" "/?"
exit /b %ERRORLEVEL%

:WriteError
for /F "delims=" %%E in ('echo prompt $E^| cmd') do set "ESC=%%E"
echo %ESC%[31m[ERROR] %~1%ESC%[0m
exit /b 0
