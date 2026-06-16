@echo off & chcp 65001 >nul & setlocal
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: WSL 实例命令模板
:::::::::::::::::::::::::::::::::::::::::::::::::::

:: 实例基本信息(必填)
set "WSL_name=wsl.1"
set "WSL_user=john"

:: 支持填写 .tar 结尾的文件路径（优先检测）或在线发行版名称(可用 wsl -l -o 查看)
:: set "WSL_source=%~dp0wsl.automng\ubuntu-22.backup.tar"
set "WSL_source=Ubuntu"





:::::::::::::::::::::::::::::::::::::::::::::::::::
:: 可选配置
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: 此实例的最终 Windows 安装目录
set "WSL_install_dir=%~dp0\data\wsl\%WSL_name%"
:: 默认备份目录，后续 mng backup / mng export 可使用此目录
set "WSL_backup_dir=%~dp0\data\wsl.backup\%WSL_name%"
:: 默认 Linux 工作目录。留空或 ~ 表示用户家目录。
set "WSL_default_workdir=~"
:: WSL 版本。通常使用 2；留空时可由系统默认值决定。
set "WSL_version=2"
:: 调试开关，设置为 1 / true / yes / on / debug 时，后续 kit 可输出调试信息。
set "WSL_KIT_verbose="



:::::::::::::::::::::::::::::::::::::::::::::::::::
:: /etc/wsl.conf 和内置服务定义
:: 配置不表示立即生效，需执行如 wsl.1.cmd mng 来进行应用。
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: 留空表示 mng 不主动修改；enable/disable 表示 mng 使用此默认动作
set "WSL_systemd="
:: SSH 配置不表示立即启用，仅作为 mng ssh.enable 的默认参数。
set "WSL_SSH_port="
set "WSL_SSH_key=%USERPROFILE%\.ssh\id_rsa"



:::::::::::::::::::::::::::::::::::::::::::::::::::
:: %USERPROFILE%\.wslconfig 定义
:: 配置不表示立即生效，需执行如 wsl.1.cmd mng.global 来进行应用
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: 留空表示 mng 不主动修改；mirrored/nat 表示 mng 使用此默认网络模式
:: 注意：网络模式是用户级 WSL2 全局配置，不是单实例配置。
set "WSL_network_mode="
:: 以下网络附属项仅在 WSL_network_mode 非空并应用网络配置时生效。
set "WSL_network_dns_tunneling="
set "WSL_network_auto_proxy="
set "WSL_network_host_loopback="




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

call "%WSL_KIT%" %*
exit /b %ERRORLEVEL%
