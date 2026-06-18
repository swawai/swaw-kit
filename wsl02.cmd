@echo off & chcp 65001 >nul & setlocal & set "WSL_KIT_PROTOCOL=1"
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: 实例基本信息(必填)
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: 绑定实例名称 (wsl -l 显示值) 和 wsl 中的 Linux 用户名 (安装时会自动创建)
set "WSL_name=wsl02"
set "WSL_user=john"

:: 支持填写归档路径（优先检测）或在线发行版名称 (wsl -l -o 可查看)
:: set "WSL_source=%~dp0wsl.automng\ubuntu-22.backup.tar"
set "WSL_source=Debian"



:::::::::::::::::::::::::::::::::::::::::::::::::::
:: 可选配置
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: 此实例的最终 Windows 安装目录
set "WSL_install_dir=%~dp0\data\wsl\%WSL_name%"

:: 默认备份目录，后续 ctl backup / ctl backup <path> / ctl backup list 可使用此目录
set "WSL_backup_dir=%~dp0\data\wsl.backup\%WSL_name%"

:: 默认 Linux 工作目录。留空或 ~ 表示用户家目录。
set "WSL_default_workdir=~"

:: WSL 版本。通常使用 2；留空时可由系统默认值决定。
set "WSL_version=2"

:: 选择备份包格式，支持: tar / tar.gz / tar.xz / vhd
set "WSL_export_format=tar"

:: 调试开关，设置为 1 / true / yes / on / debug 时，后续 kit 可输出调试信息。
set "WSL_KIT_verbose="

:: 可选：指定 help 语言 zh-CN / en；留空自动检测。
:: set "WSL_KIT_HELP_LANG=zh-CN"

:: 开启 ssh 时会顺便导入下面设置的公钥
:: set "WSL_SSH_public_key=%USERPROFILE%\.ssh\id_rsa.pub"





:::::::::::::::::::::::::::::::::::::::::::::::::::
:: 不要修改下面的内容
:::::::::::::::::::::::::::::::::::::::::::::::::::
set "WSL_KIT=%~dp0_lib\wsl_instance_kit\kit.cmd"

if not exist "%WSL_KIT%" (
    echo WSL instance kit not found:
    echo   "%WSL_KIT%"
    echo.
    echo 当前只创建了入口模板；请先实现 _lib\wsl_instance_kit\kit.cmd 后再运行此命令。
    exit /b 1
)

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
