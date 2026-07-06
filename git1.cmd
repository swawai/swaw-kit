@echo off & chcp 65001 >nul & setlocal
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: Copy this file as, for example, git2.cmd or git.work.cmd, then customize the Git identity settings below.
:: 复制本文件为(例如): git2.cmd 或 git.work.cmd，然后自定义下面的 Git 身份配置。
:::::::::::::::::::::::::::::::::::::::::::::::::::
set "GIT_IDENTITY_NAME=user1"
set "GIT_IDENTITY_EMAIL=user1@example.com"
set "GIT_IDENTITY_SSH_KEY=%USERPROFILE%\.ssh\id_ed25519"
set "GIT_IDENTITY_DEFAULT_TERMINAL=cmd"


:::::::::::::::::::::::::::::::::::::::::::::::::::
:: Optional: bind commit signing for this identity. Uncomment to enable.
:: 可选：为这个身份绑定提交签名。取消注释以启用。
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: set "GIT_IDENTITY_SIGNING_KEY="
:: set "GIT_IDENTITY_GPG_FORMAT=ssh"



:::::::::::::::::::::::::::::::::::::::::::::::::::
:: Optional: add extra ssh options used by Git remotes. Keep empty for the default safe options.
:: 可选：追加 Git 远程 SSH 参数。留空则使用默认安全参数。
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: set "GIT_IDENTITY_SSH_OPTS=-o IdentityAgent=none -o IdentitiesOnly=yes"
:: Advanced: override the complete SSH command. When set, this wins over GIT_IDENTITY_SSH_KEY / GIT_IDENTITY_SSH_OPTS.
:: 高级：覆盖完整 SSH 命令。设置后优先于 GIT_IDENTITY_SSH_KEY / GIT_IDENTITY_SSH_OPTS。
:: set "GIT_SSH_COMMAND=ssh -F %USERPROFILE%\.ssh\config-work"



:::::::::::::::::::::::::::::::::::::::::::::::::::
:: Optional: force help language: zh-CN / en. Auto-detect when unset.
:: 可选：指定 help 语言: zh-CN / en。未设置则自动检测。
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: set "GIT_IDENTITY_HELP_LANG=zh-CN"



:::::::::::::::::::::::::::::::::::::::::::::::::::
:: Do not edit anything below.
:: 下面的不要做任何修改。
:::::::::::::::::::::::::::::::::::::::::::::::::::
set "GIT_IDENTITY_KIT=%~dp0_lib\git_identity_kit\kit.cmd"

if exist "%GIT_IDENTITY_KIT%" goto :GitIdentityKitFound
echo [ERROR] Git identity kit not found:
echo   "%GIT_IDENTITY_KIT%"
echo.
echo Missing _lib\git_identity_kit\kit.cmd next to this entry file.
exit /b 1

:GitIdentityKitFound
set "GIT_IDENTITY_ENTRY_COMMAND=%~n0"
set "GIT_IDENTITY_ENTRY_FILE=%~f0"
call "%GIT_IDENTITY_KIT%" %*
exit /b %ERRORLEVEL%
