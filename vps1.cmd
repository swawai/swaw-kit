@echo off & chcp 65001 >nul & setlocal
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: Copy this file as, for example, vps2.cmd or vps1.userA.cmd/vps1.userB.cmd, then customize the SSH host settings below:
:: 复制本文件为(例如): vps2.cmd 或 vps1.userA.cmd vps1.userB.cmd，然后自定义下面的 SSH 主机配置：
:::::::::::::::::::::::::::::::::::::::::::::::::::
set "REMOTE_HOST=myvps1.example.com"
set "REMOTE_PORT=22"
set "REMOTE_USER=root"
set "REMOTE_KEY=%USERPROFILE%\.ssh\id_rsa"
:: ↑ Automatically treats %REMOTE_KEY%.pub as the public key location
:: ↑ 会自动将 %REMOTE_KEY%.pub 视为公钥位置



:: SSH 参数 / SSH options:
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: Ignore known_hosts host-key checking. This reduces errors after VPS reinstall, but weakens security. Uncomment to enable:
:: 忽略 known_hosts 中的主机指纹校验。可减少 VPS 重装后的报错，但会减弱安全性。取消注释以启用:
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: set "REMOTE_KIT_SSH_HOSTKEY_OPTS=-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o GlobalKnownHostsFile=/dev/null"



:::::::::::::::::::::::::::::::::::::::::::::::::::
:: Optional: reduce ssh/scp output noise. Uncomment to enable:
:: 可选: 减少 ssh/scp 输出噪音。取消注释以启用:
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: set "REMOTE_KIT_SSH_LOG_OPTS=-o LogLevel=ERROR"



:::::::::::::::::::::::::::::::::::::::::::::::::::
:: Optional: print wrapper-level ssh/scp debug commands. Uncomment to enable:
:: 可选: 打印包装层 ssh/scp 调试命令。取消注释以启用:
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: set "REMOTE_KIT_VERBOSE=1"



:::::::::::::::::::::::::::::::::::::::::::::::::::
:: Optional: force help language: zh-CN / en. Auto-detect when unset:
:: 可选: 指定 help 的语言: zh-CN / en。未设置则自动检测：
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: set "REMOTE_KIT_HELP_LANG=zh-CN"








:::::::::::::::::::::::::::::::::::::::::::::::::::
:: Do not edit anything below:
:: 下面的不要做任何修改:
:::::::::::::::::::::::::::::::::::::::::::::::::::
if /i "%~1"=="-h" goto :ShowRemoteKitHelp
if /i "%~1"=="--help" goto :ShowRemoteKitHelp
if "%~1"=="/?" goto :ShowRemoteKitHelp
call "%~dp0_lib\ssh_remote_kit\kit.cmd" "%REMOTE_PORT%" "%REMOTE_HOST%" "%REMOTE_USER%" "%REMOTE_KEY%" %*
exit /b %ERRORLEVEL%
:ShowRemoteKitHelp
call "%~dp0_lib\ssh_remote_kit\kit.cmd" -h "%~n0"
exit /b 0
