@echo off
chcp 65001 >nul
setlocal

if /i "%~1"=="--entry-file" (
    set "WSL_ENTRY_FILE=%~2"
    set "WSL_KIT_PARSE_ENTRY_FILE=1"
    shift /1
    shift /1
)

if "%~1"=="-h" goto :ShowHelp
if "%~1"=="--help" goto :ShowHelp
if "%~1"=="/?" goto :ShowHelp
goto :Main

:ShowHelp
set "helpLanguage="
set "helpLanguageCandidate=%~2"
if /i "%helpLanguageCandidate%"=="zh" set "helpLanguage=%helpLanguageCandidate%"
if /i "%helpLanguageCandidate%"=="en" set "helpLanguage=%helpLanguageCandidate%"
if /i "%helpLanguageCandidate:~0,3%"=="zh-" set "helpLanguage=%helpLanguageCandidate%"
if /i "%helpLanguageCandidate:~0,3%"=="zh_" set "helpLanguage=%helpLanguageCandidate%"
if /i "%helpLanguageCandidate:~0,3%"=="en-" set "helpLanguage=%helpLanguageCandidate%"
if /i "%helpLanguageCandidate:~0,3%"=="en_" set "helpLanguage=%helpLanguageCandidate%"
set "commandName=%~2"
if defined helpLanguage set "commandName="
if not defined commandName if defined WSL_ENTRY_FILE for %%I in ("%WSL_ENTRY_FILE%") do set "commandName=%%~nI"
if not defined commandName set "commandName=wsl_instance_kit"
if defined helpLanguage (
    PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0help.ps1" -CommandName "%commandName%" -Language "%helpLanguage%"
) else (
    PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0help.ps1" -CommandName "%commandName%"
)
exit /b %ERRORLEVEL%

:Main
if "%~1"=="" (
    if "%WSL_KIT_ARGS_READY%"=="1" goto :RunKit
    set "WSL_KIT_ARG_COUNT=0"
    goto :RunKit
)

set "WSL_KIT_ARG_COUNT=0"

:ArgLoop
if "%~1"=="" if not [%1]==[""] goto :RunKit
set /a WSL_KIT_ARG_COUNT+=1
set "WSL_KIT_ARG_%WSL_KIT_ARG_COUNT%=%~1"
shift /1
goto :ArgLoop

:RunKit
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0kit.ps1"
exit /b %ERRORLEVEL%
