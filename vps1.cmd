@echo off & chcp 65001 >nul & setlocal
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: Copy this file as vps2.cmd / vps1.userA.cmd, then edit HOST and the
:: embedded ssh_config block below.
:::::::::::::::::::::::::::::::::::::::::::::::::::
set "HOST=vps1"


goto :REMOTE_KIT_AFTER_SSH_CONFIG
Host %HOST%
  HostName myvps1.example.com
  User root
  Port 22
  IdentityFile ~/.ssh/id_rsa
  StrictHostKeyChecking accept-new
:REMOTE_KIT_AFTER_SSH_CONFIG



:::::::::::::::::::::::::::::::::::::::::::::::::::
:: Do not edit anything below:
:::::::::::::::::::::::::::::::::::::::::::::::::::
if /i "%~1"=="-h" goto :ShowRemoteKitHelp
if /i "%~1"=="--help" goto :ShowRemoteKitHelp
if "%~1"=="/?" goto :ShowRemoteKitHelp
set "REMOTE_KIT_ENTRY_FILE=%~f0"
call "%~dp0_lib\ssh_remote_kit\kit.cmd" "0" "%HOST%" "%HOST%" "__REMOTE_KIT_SSH_CONFIG_IDENTITY__" %*
exit /b %ERRORLEVEL%
:ShowRemoteKitHelp
call "%~dp0_lib\ssh_remote_kit\kit.cmd" -h "%~n0"
exit /b 0
