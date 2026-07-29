@echo off & chcp 65001 >nul <nul & setlocal DisableDelayedExpansion & set "SSH_ACCESS_PROTOCOL=1"
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: SSH access identity (required)
:: 此入口绑定的一套 SSH 访问身份（必填）
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: Private key path. The public key path is derived by appending ".pub".
:: 私钥路径；公钥路径固定由该路径追加 ".pub" 推导。
set "SSH_ACCESS_PRIVATE_KEY_PATH=%USERPROFILE%\.ssh\id_ed25519_sshaccess1_dev"

:: Local Windows user granted SSH sign-in access.
:: 被授予 SSH 登录权限的 Windows 本机用户。
set "SSH_ACCESS_USER=%USERNAME%"


:::::::::::::::::::::::::::::::::::::::::::::::::::
:: Optional configuration
:: 可选配置.
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: OpenSSH key type passed to ssh-keygen -t.
:: 传给 ssh-keygen -t 的 OpenSSH 密钥类型。
set "SSH_ACCESS_KEY_TYPE=ed25519"

:: Public key comment. Do not store a passphrase in this file.
:: 公钥注释；不要在此文件中保存私钥口令。
set "SSH_ACCESS_KEY_COMMENT=sshaccess1.dev@%COMPUTERNAME%"





:::::::::::::::::::::::::::::::::::::::::::::::::::
:: Do not edit below.
:: 下面的内容不要修改。
:::::::::::::::::::::::::::::::::::::::::::::::::::
set "SSH_ACCESS_KIT=%~dp0_lib\ssh_access\kit.cmd"

if exist "%SSH_ACCESS_KIT%" goto :SshAccessKitFound
echo [ERROR] SSH access kit not found:
echo   "%SSH_ACCESS_KIT%"
echo.
echo Missing _lib\ssh_access\kit.cmd next to this entry file.
exit /b 1

:SshAccessKitFound
set "SSH_ACCESS_ENTRY_COMMAND=%~n0"
set "SSH_ACCESS_ENTRY_FILE=%~f0"

:: Tail-call the kit so cmd.exe does not parse forwarded arguments twice.
"%SSH_ACCESS_KIT%" %*
