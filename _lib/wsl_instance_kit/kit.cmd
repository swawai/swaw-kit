@echo off
chcp 65001 >nul
setlocal DisableDelayedExpansion

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
call :ResolveHelpLanguage "%helpLanguageCandidate%"
set "commandName=%~2"
if defined helpLanguage set "commandName="
set "entryFileName="
call :ResolveEntryNames
if defined helpLanguage (
    call :ShowResolvedHelp
) else (
    PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0help.ps1" -CommandName "%commandName%"
)
exit /b %ERRORLEVEL%

:Main
if "%~1"=="" (
    if "%WSL_KIT_ARGS_READY%"=="1" goto :TryFastPath
    set "WSL_KIT_ARG_COUNT=0"
    goto :TryFastPath
)

set "WSL_KIT_ARG_COUNT=0"

:ArgLoop
if "%~1"=="" if not [%1]==[""] goto :TryFastPath
set /a WSL_KIT_ARG_COUNT+=1
set "WSL_KIT_ARG_%WSL_KIT_ARG_COUNT%=%~1"
shift /1
goto :ArgLoop

:TryFastPath
if defined WSL_KIT_PARSE_ENTRY_FILE goto :RunKit
if defined WSL_KIT_verbose goto :RunKit
if "%WSL_KIT_ARG_COUNT%"=="" set "WSL_KIT_ARG_COUNT=0"
if "%WSL_KIT_ARG_COUNT%"=="0" goto :RunPassthroughFastPath

set "fastVerb=%WSL_KIT_ARG_1%"
if /i "%fastVerb%"==".help" goto :RunHelpFastPath
if /i "%fastVerb%"=="-h" goto :RunHelpFastPath
if /i "%fastVerb%"=="--help" goto :RunHelpFastPath
if /i "%fastVerb%"=="/?" goto :RunHelpFastPath
if /i "%fastVerb%"==".t" goto :RunTerminateFastPath
if /i "%fastVerb%"==".vm" goto :RunVmFastPath
if /i "%fastVerb%"==".dir" goto :RunDirFastPath
if "%fastVerb:~0,1%"=="." (
    if "%fastVerb%"=="." goto :RunPassthroughFastPath
    call :IsKnownToolVerb "%fastVerb%"
    if not errorlevel 1 goto :RunKit
)
goto :RunPassthroughFastPath

:RunHelpFastPath
if not "%WSL_KIT_ARG_COUNT%"=="1" if not "%WSL_KIT_ARG_COUNT%"=="2" goto :RunKit

set "helpLanguage="
if "%WSL_KIT_ARG_COUNT%"=="2" (
    call :ResolveHelpLanguage "%WSL_KIT_ARG_2%"
    if not defined helpLanguage goto :RunKit
)

set "commandName="
set "entryFileName="
call :ResolveEntryNames
if defined helpLanguage (
    call :ShowResolvedHelp
    exit /b %ERRORLEVEL%
)

PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0help.ps1" -CommandName "%commandName%" -EntryFileName "%entryFileName%"
exit /b %ERRORLEVEL%

:RunTerminateFastPath
if not "%WSL_KIT_ARG_COUNT%"=="1" goto :RunKit
if not defined WSL_name goto :RunKit
call :RejectComplexPassthroughArg "%WSL_name%"
if errorlevel 1 goto :RunKit
wsl.exe --terminate %WSL_name%
exit /b %ERRORLEVEL%

:RunVmFastPath
if not "%WSL_KIT_ARG_COUNT%"=="2" goto :RunKit
if /i "%WSL_KIT_ARG_2%"=="-s" (
    wsl.exe --shutdown
    exit /b %ERRORLEVEL%
)
if /i "%WSL_KIT_ARG_2%"=="default" (
    if not defined WSL_name goto :RunKit
    call :RejectComplexPassthroughArg "%WSL_name%"
    if errorlevel 1 goto :RunKit
    wsl.exe --set-default %WSL_name%
    exit /b %ERRORLEVEL%
)
goto :RunKit

:RunDirFastPath
if not "%WSL_KIT_ARG_COUNT%"=="2" goto :RunKit
set "targetDir="
if /i "%WSL_KIT_ARG_2%"=="install" set "targetDir=%WSL_install_dir%"
if /i "%WSL_KIT_ARG_2%"=="backup" set "targetDir=%WSL_backup_dir%"
if /i "%WSL_KIT_ARG_2%"=="downloads" if defined WSL_ENTRY_FILE for %%I in ("%WSL_ENTRY_FILE%") do set "targetDir=%%~dpIdata\wsl.downloads"
if not defined targetDir goto :RunKit
if not exist "%targetDir%\" mkdir "%targetDir%" >nul 2>nul
if errorlevel 1 exit /b 1
start "" explorer.exe "%targetDir%"
exit /b 0

:RunPassthroughFastPath
if not defined WSL_name goto :RunKit
call :CanRunSimplePassthroughFastPath
if errorlevel 1 goto :RunKit

set "wslExtraArgs="
if not "%WSL_KIT_ARG_COUNT%"=="0" (
    call :BuildPassthroughArgs
)

if defined WSL_user (
    if defined WSL_default_workdir (
        wsl.exe -d %WSL_name% -u %WSL_user% --cd %WSL_default_workdir% %wslExtraArgs%
    ) else (
        wsl.exe -d %WSL_name% -u %WSL_user% %wslExtraArgs%
    )
) else (
    if defined WSL_default_workdir (
        wsl.exe -d %WSL_name% --cd %WSL_default_workdir% %wslExtraArgs%
    ) else (
        wsl.exe -d %WSL_name% %wslExtraArgs%
    )
)
exit /b %ERRORLEVEL%

:CanRunSimplePassthroughFastPath
call :RejectComplexPassthroughArg "%WSL_name%"
if errorlevel 1 exit /b 1
if defined WSL_user (
    call :RejectComplexPassthroughArg "%WSL_user%"
    if errorlevel 1 exit /b 1
)
if defined WSL_default_workdir (
    call :RejectComplexPassthroughArg "%WSL_default_workdir%"
    if errorlevel 1 exit /b 1
)
if "%WSL_KIT_ARG_COUNT%"=="0" exit /b 0
call :RejectArgEnvironmentBeforeDelayedExpansion
if errorlevel 1 exit /b 1
setlocal EnableDelayedExpansion
for /l %%I in (1,1,%WSL_KIT_ARG_COUNT%) do (
    set "candidate=!WSL_KIT_ARG_%%I!"
    if "!candidate!"=="" exit /b 1
)
endlocal
exit /b 0

:RejectArgEnvironmentBeforeDelayedExpansion
rem The fast path emits unquoted argv; reject anything cmd.exe can reinterpret.
set WSL_KIT_ARG_ | find " " >nul 2>nul
if not errorlevel 1 exit /b 1
set WSL_KIT_ARG_ | find "%%" >nul 2>nul
if not errorlevel 1 exit /b 1
set WSL_KIT_ARG_ | find """" >nul 2>nul
if not errorlevel 1 exit /b 1
set WSL_KIT_ARG_ | find "!" >nul 2>nul
if not errorlevel 1 exit /b 1
set WSL_KIT_ARG_ | find "&" >nul 2>nul
if not errorlevel 1 exit /b 1
set WSL_KIT_ARG_ | find "|" >nul 2>nul
if not errorlevel 1 exit /b 1
set WSL_KIT_ARG_ | find "<" >nul 2>nul
if not errorlevel 1 exit /b 1
set WSL_KIT_ARG_ | find ">" >nul 2>nul
if not errorlevel 1 exit /b 1
set WSL_KIT_ARG_ | find "^" >nul 2>nul
if not errorlevel 1 exit /b 1
set WSL_KIT_ARG_ | find "(" >nul 2>nul
if not errorlevel 1 exit /b 1
set WSL_KIT_ARG_ | find ")" >nul 2>nul
if not errorlevel 1 exit /b 1
exit /b 0

:RejectComplexPassthroughArg
set "candidate=%~1"
if "%candidate%"=="" exit /b 1
set "candidateNoQuote=%candidate:"=%"
if not "%candidateNoQuote%"=="%candidate%" exit /b 1
if not "%candidate: =%"=="%candidate%" exit /b 1
if not "%candidate:&=%"=="%candidate%" exit /b 1
if not "%candidate:|=%"=="%candidate%" exit /b 1
if not "%candidate:<=%"=="%candidate%" exit /b 1
if not "%candidate:>=%"=="%candidate%" exit /b 1
if not "%candidate:^=%"=="%candidate%" exit /b 1
if not "%candidate:(=%"=="%candidate%" exit /b 1
if not "%candidate:)=%"=="%candidate%" exit /b 1
exit /b 0

:BuildPassthroughArgs
rem Args are prevalidated as simple literals before delayed expansion is enabled.
if "%WSL_KIT_ARG_COUNT%"=="0" goto :eof
setlocal EnableDelayedExpansion
set "built="
for /l %%I in (1,1,%WSL_KIT_ARG_COUNT%) do (
    set "built=!built! !WSL_KIT_ARG_%%I!"
)
endlocal & set "wslExtraArgs=%built%"
goto :eof

:IsKnownToolVerb
set "knownVerb=%~1"
if /i "%knownVerb%"==".status" exit /b 0
if /i "%knownVerb%"==".doctor" exit /b 0
if /i "%knownVerb%"==".code" exit /b 0
if /i "%knownVerb%"==".cursor" exit /b 0
if /i "%knownVerb%"==".vm" exit /b 0
if /i "%knownVerb%"==".t" exit /b 0
if /i "%knownVerb%"==".install" exit /b 0
if /i "%knownVerb%"==".backup" exit /b 0
if /i "%knownVerb%"==".dir" exit /b 0
if /i "%knownVerb%"==".alive" exit /b 0
if /i "%knownVerb%"==".port" exit /b 0
if /i "%knownVerb%"==".user" exit /b 0
if /i "%knownVerb%"==".sshd" exit /b 0
if /i "%knownVerb%"==".systemd" exit /b 0
if /i "%knownVerb%"==".delete" exit /b 0
if /i "%knownVerb%"==".relocate" exit /b 0
if /i "%knownVerb%"==".help" exit /b 0
exit /b 1

:ResolveHelpLanguage
set "helpLanguage="
set "candidate=%~1"
if /i "%candidate%"=="zh" set "helpLanguage=zh-CN"
if /i "%candidate%"=="en" set "helpLanguage=en"
if /i "%candidate:~0,3%"=="zh-" set "helpLanguage=zh-CN"
if /i "%candidate:~0,3%"=="zh_" set "helpLanguage=zh-CN"
if /i "%candidate:~0,3%"=="en-" set "helpLanguage=en"
if /i "%candidate:~0,3%"=="en_" set "helpLanguage=en"
goto :eof

:ResolveEntryNames
if not defined commandName if defined WSL_ENTRY_FILE for %%I in ("%WSL_ENTRY_FILE%") do (
    set "commandName=%%~nI"
    set "entryFileName=%%~nxI"
)
if not defined commandName set "commandName=wsl_instance_kit"
if not defined entryFileName set "entryFileName=%commandName%.cmd"
goto :eof

:ShowResolvedHelp
if /i "%helpLanguage%"=="en" (
    call :PrintHelpTemplate
    exit /b %ERRORLEVEL%
)

PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0help.ps1" -CommandName "%commandName%" -EntryFileName "%entryFileName%" -Language "%helpLanguage%"
exit /b %ERRORLEVEL%

:PrintHelpTemplate
set "helpPath=%~dp0help\en.txt"
if not exist "%helpPath%" set "helpPath=%~dp0help\en.txt"
if not exist "%helpPath%" (
    echo [ERROR] Help template not found: "%helpPath%"
    exit /b 1
)

for /f "usebackq tokens=1,* delims=:" %%A in (`findstr /n "^.*" "%helpPath%"`) do (
    set "helpLine=%%B"
    setlocal EnableDelayedExpansion
    if not defined helpLine (
        echo(
    ) else (
        set "helpLine=!helpLine:{{ENTRY_FILE}}=%entryFileName%!"
        set "helpLine=!helpLine:{{COMMAND}}=%commandName%!"
        echo(!helpLine!
    )
    endlocal
)
exit /b 0

:RunKit
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0kit.ps1"
exit /b %ERRORLEVEL%
