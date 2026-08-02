@echo off
chcp 65001 >nul <nul
setlocal DisableDelayedExpansion

if not "%RDP_CLIENT_PROTOCOL%"=="1" goto :InvalidEntryProtocol
if not defined RDP_ENTRY_COMMAND set "RDP_ENTRY_COMMAND=rdp"

if "%~1"=="" goto :Connect
if /i "%~1"==".help" goto :ShowHelp
if /i "%~1"==".h" goto :ShowHelp
if "%~1"=="-h" goto :ShowHelp
if /i "%~1"=="--help" goto :ShowHelp
if /i "%~1"==".rdp" goto :GenerateRdp
if /i "%~1"==".hosts" goto :Hosts
if /i "%~1"==".sign" goto :Signing
goto :UnknownCommand

:Connect
set "RDP_CLIENT_LAUNCH=-Launch"
set "RDP_CLIENT_FORCE="
goto :RunRdp

:GenerateRdp
set "RDP_CLIENT_LAUNCH="
set "RDP_CLIENT_FORCE="
if /i not "%~2"=="create" goto :InvalidRdpCommand
if "%~3"=="" goto :RunRdp
if /i not "%~3"=="--force" goto :InvalidRdpCommand
if not "%~4"=="" goto :InvalidRdpCommand
set "RDP_CLIENT_FORCE=-Force"
goto :RunRdp

:RunRdp
if not defined RDP_ENTRY_FILE goto :InvalidEntryFile
set "RDP_CONNECT_SCRIPT=%~dp0connect.ps1"
if not exist "%RDP_CONNECT_SCRIPT%" (
    echo [ERROR] RDP connection script not found:
    echo   "%RDP_CONNECT_SCRIPT%"
    exit /b 1
)

PowerShell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%RDP_CONNECT_SCRIPT%" -EntryFile "%RDP_ENTRY_FILE%" -CommandName "%RDP_ENTRY_COMMAND%" %RDP_CLIENT_LAUNCH% %RDP_CLIENT_FORCE%
exit /b %ERRORLEVEL%

:Signing
set "RDP_SIGNING_DRY_RUN="
if /i "%~2"=="status" goto :SigningStatus
if /i "%~2"=="install" goto :SigningInstall
if /i "%~2"=="remove" goto :SigningRemove
if /i "%~2"=="open" goto :SigningOpen
goto :InvalidSigningCommand

:SigningStatus
if not "%~3"=="" goto :InvalidSigningCommand
set "RDP_SIGNING_ACTION=status"
goto :RunSigning

:SigningInstall
set "RDP_SIGNING_ACTION=install"
if "%~3"=="" goto :RunSigning
if /i not "%~3"=="--dry-run" goto :InvalidSigningCommand
if not "%~4"=="" goto :InvalidSigningCommand
set "RDP_SIGNING_DRY_RUN=-DryRun"
goto :RunSigning

:SigningRemove
if not "%~3"=="" goto :InvalidSigningCommand
set "RDP_SIGNING_ACTION=remove"
goto :RunSigning

:SigningOpen
if not "%~3"=="" goto :InvalidSigningCommand
set "RDP_SIGNING_ACTION=open"

:RunSigning
set "RDP_SIGNING_SCRIPT=%~dp0signing.ps1"
if not exist "%RDP_SIGNING_SCRIPT%" (
    echo [ERROR] RDP signing script not found:
    echo   "%RDP_SIGNING_SCRIPT%"
    exit /b 1
)

PowerShell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%RDP_SIGNING_SCRIPT%" -Action "%RDP_SIGNING_ACTION%" -CommandName "%RDP_ENTRY_COMMAND%" %RDP_SIGNING_DRY_RUN%
exit /b %ERRORLEVEL%

:Hosts
set "RDP_HOSTS_UAC="
set "RDP_HOSTS_DRY_RUN="
if /i "%~2"=="status" goto :HostsStatus
if /i "%~2"=="install" goto :HostsInstall
if /i "%~2"=="remove" goto :HostsRemove
if /i "%~2"=="cleanup" goto :HostsCleanup
goto :InvalidHostsCommand

:HostsStatus
set "RDP_HOSTS_ACTION=status"
if not "%~3"=="" goto :InvalidHostsCommand
goto :RunHosts

:HostsInstall
set "RDP_HOSTS_ACTION=install"
goto :ParseHostsMutation

:HostsRemove
set "RDP_HOSTS_ACTION=remove"
goto :ParseHostsMutation

:HostsCleanup
set "RDP_HOSTS_ACTION=cleanup"
if "%~3"=="" goto :RunHosts
if not "%~4"=="" goto :InvalidHostsCommand
if /i "%~3"=="--uac" set "RDP_HOSTS_UAC=-Uac"
if /i "%~3"=="--uac" goto :RunHosts
if /i "%~3"=="--dry-run" set "RDP_HOSTS_DRY_RUN=-DryRun"
if /i "%~3"=="--dry-run" goto :RunHosts
goto :InvalidHostsCommand

:ParseHostsMutation
if "%~3"=="" goto :RunHosts
if /i not "%~3"=="--uac" goto :InvalidHostsCommand
if not "%~4"=="" goto :InvalidHostsCommand
set "RDP_HOSTS_UAC=-Uac"

:RunHosts
if not defined RDP_ENTRY_FILE goto :InvalidEntryFile
set "RDP_HOSTS_SCRIPT=%~dp0hosts.ps1"
if not exist "%RDP_HOSTS_SCRIPT%" (
    echo [ERROR] RDP hosts script not found:
    echo   "%RDP_HOSTS_SCRIPT%"
    exit /b 1
)

PowerShell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%RDP_HOSTS_SCRIPT%" -EntryFile "%RDP_ENTRY_FILE%" -Action "%RDP_HOSTS_ACTION%" -HostAlias "%RDP_HOST_ALIAS%" -CommandName "%RDP_ENTRY_COMMAND%" %RDP_HOSTS_UAC% %RDP_HOSTS_DRY_RUN%
exit /b %ERRORLEVEL%

:ShowHelp
if not "%~3"=="" goto :InvalidHelpCommand
set "RDP_HELP_SCRIPT=%~dp0help.ps1"
if not exist "%RDP_HELP_SCRIPT%" (
    echo [ERROR] RDP help script not found:
    echo   "%RDP_HELP_SCRIPT%"
    exit /b 1
)

PowerShell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%RDP_HELP_SCRIPT%" -CommandName "%RDP_ENTRY_COMMAND%" -Language "%~2"
exit /b %ERRORLEVEL%

:InvalidHelpCommand
echo [ERROR] Help usage:
echo   "%RDP_ENTRY_COMMAND% .help [zh^|en]"
exit /b 1

:InvalidRdpCommand
echo [ERROR] RDP file usage:
echo   "%RDP_ENTRY_COMMAND% .rdp create [--force]"
exit /b 1

:InvalidHostsCommand
echo [ERROR] Hosts usage:
echo   "%RDP_ENTRY_COMMAND% .hosts status"
echo   "%RDP_ENTRY_COMMAND% .hosts install [--uac]"
echo   "%RDP_ENTRY_COMMAND% .hosts remove [--uac]"
echo   "%RDP_ENTRY_COMMAND% .hosts cleanup [--dry-run^|--uac]"
exit /b 1

:InvalidSigningCommand
echo [ERROR] Sign usage:
echo   "%RDP_ENTRY_COMMAND% .sign status"
echo   "%RDP_ENTRY_COMMAND% .sign install [--dry-run]"
echo   "%RDP_ENTRY_COMMAND% .sign remove"
echo   "%RDP_ENTRY_COMMAND% .sign open"
exit /b 1

:UnknownCommand
echo [ERROR] Unknown RDP command: %~1
echo Run "%RDP_ENTRY_COMMAND% .help" to view the commands currently available.
exit /b 1

:InvalidEntryProtocol
echo [ERROR] This RDP entry is missing RDP_CLIENT_PROTOCOL=1.
echo Copy Favorites\template.rdp1.cmd again or update the entry header.
exit /b 1

:InvalidEntryFile
echo [ERROR] This RDP entry did not provide RDP_ENTRY_FILE.
echo Copy Favorites\template.rdp1.cmd again or update the entry footer.
exit /b 1
