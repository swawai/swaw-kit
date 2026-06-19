@echo off & chcp 65001 >nul & setlocal & set "WSL_KIT_PROTOCOL=1"
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: 实例基本信息(必填)
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: wsl -l 中显示的实例名称，也是本工具的安装/使用等命令会一直绑定的实例ID
set "WSL_name=wsl01"
:: 安装时创建并默认使用的 Linux 用户
set "WSL_user=john"

:: 安装/重装的镜像源，可以是归档路径(优先检测),或在线发行版名 (wsl -l -o 可查看)
:: set "WSL_source=%~dp0wsl.automng\ubuntu-22.backup.tar"
set "WSL_source=Debian"



:::::::::::::::::::::::::::::::::::::::::::::::::::
:: 可选配置
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: 此实例在 Windows 上的安装目录
set "WSL_install_dir=%~dp0\data\wsl\%WSL_name%"
:: 默认备份目录，后续 .backup / .backup <path> / .backup list 命令默认使用此目录
set "WSL_backup_dir=%~dp0\data\wsl.backup\%WSL_name%"
:: 默认 Linux 工作目录; 留空或 ~ 表示用户家目录。
set "WSL_default_workdir=~"
:: 备份格式,支持：.backup fixed format: tar / tar.gz / tar.xz / vhd 或留空
set "WSL_export_format=tar"
:: WSL 版本。通常使用 2; 留空时可由系统默认值决定。
set "WSL_version=2"
:: .sshd enable 时会顺便导入下面设置的公钥
:: set "WSL_SSH_public_key=%USERPROFILE%\.ssh\id_rsa.pub"
:: Optional env file loaded into this command process only.
:: set "WSL_env_file=%userprofile%\secrets\%WSL_name%.env"
:: 调试开关，设置为 1 / true / yes / on / debug 时，后续 kit 可输出调试信息。
set "WSL_KIT_verbose="
:: 可选：指定 help 语言 zh-CN / en；留空自动检测。
:: set "WSL_KIT_HELP_LANG=zh-CN"






:::::::::::::::::::::::::::::::::::::::::::::::::::
:: 不要修改下面的内容
:::::::::::::::::::::::::::::::::::::::::::::::::::
set "WSL_KIT=%~dp0_lib\wsl_instance_kit\kit.cmd"

if exist "%WSL_KIT%" goto :WslKitFound
call :WriteError "WSL instance kit not found:"
echo   "%WSL_KIT%"
echo.
call :WriteError "Missing _lib\wsl_instance_kit\kit.cmd next to this entry file."
exit /b 1

:WslKitFound

set "WSL_ENTRY_FILE=%~f0"
set "WSL_KIT_ARGS_READY=1"
set "WSL_KIT_ARG_COUNT=0"

:ArgLoop
if "%~1"=="" if not [%1]==[""] goto :RunWslKit
set /a WSL_KIT_ARG_COUNT+=1
set "WSL_KIT_ARG_%WSL_KIT_ARG_COUNT%=%~1"
shift /1
goto :ArgLoop

:RunWslKit
call "%WSL_KIT%"
exit /b %ERRORLEVEL%

:WriteError
for /F "delims=" %%E in ('echo prompt $E^| cmd') do set "ESC=%%E"
echo %ESC%[31m[ERROR] %~1%ESC%[0m
exit /b 0
